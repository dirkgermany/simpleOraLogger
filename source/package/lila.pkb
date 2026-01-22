create or replace PACKAGE BODY LILA AS

    ---------------------------------------------------------------
    -- Sessions and Processes
    ---------------------------------------------------------------
    -- Record representing the internal session
    TYPE t_session_rec IS RECORD (
        process_id      NUMBER(19,0),
        counter_details PLS_INTEGER := 0,
        log_level       PLS_INTEGER := 0,
        tabName_master  VARCHAR2(100)
    );

    -- Table for several processes
    TYPE t_session_tab IS TABLE OF t_session_rec;
    g_sessionList t_session_tab := null;
    
    -- Indexes for lists
    TYPE t_idx IS TABLE OF PLS_INTEGER INDEX BY BINARY_INTEGER;
    v_indexSession t_idx;    
    
    -- Record representing the process (internal and external)
    TYPE t_process_rec IS RECORD (
        id      NUMBER(19,0),
        process_name varchar2(100),
        process_start TIMESTAMP,
        process_end TIMESTAMP,
        last_update TIMESTAMP,
        steps_todo PLS_INTEGER,
        steps_done PLS_INTEGER,
        status PLS_INTEGER,
        info CLOB
    );

    ---------------------------------------------------------------
    -- Monitoring
    ---------------------------------------------------------------
    TYPE t_monitor_rec IS RECORD (
        process_id number(19,0),
        action_name varchar2(25),
        steps_done PLS_INTEGER,
        max_steps PLS_INTEGER,
        avg_action_duration number      
    );
   
    TYPE t_monitor_tab IS TABLE OF t_monitor_rec;
    g_monitorList t_monitor_tab := null;

    TYPE t_idx_monitor IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(100);
    v_indexSession_monitor t_idx_monitor;
   
    g_max_monitor_size CONSTANT PLS_INTEGER := 1000; -- Limit
    g_monitor_ptr      PLS_INTEGER := 0;             -- Aktueller Schreib-Zeiger    

    ---------------------------------------------------------------
    -- Placeholders for tables
    ---------------------------------------------------------------
    PARAM_MASTER_TABLE constant varchar2(20) := 'PH_MASTER_TABLE';
    PARAM_DETAIL_TABLE constant varchar2(20) := 'PH_DETAIL_TABLE';
    SUFFIX_DETAIL_NAME constant varchar2(16) := '_DETAIL';
    
    ---------------------------------------------------------------
    -- Functions and Procedures
    ---------------------------------------------------------------
    function getSessionRecord(p_processId number) return t_session_rec;

    /*
        Internal methods.
        Internal methods are written in lowercase and camelCase
    */
    -- run execute immediate with exception handling
    procedure run_sql(p_sqlStmt varchar2)
    as
    begin
        execute immediate p_sqlStmt;
        
    exception
        when OTHERS then
            DBMS_OUTPUT.PUT_LINE('DDL-Fehler bei: ' || p_sqlStmt);
            DBMS_OUTPUT.PUT_LINE(SQLERRM);
            RAISE;
    end;
    
    -- Checks if a database sequence exists
    function objectExists(p_objectName varchar2, p_objectType varchar2) return boolean
    as
        sqlStatement varchar2(200);
        objectCount number;
    begin
        sqlStatement := '
        select count(*)
        from user_objects
        where upper(object_name) = upper(:PH_OBJECT_NAME)
        and   upper(object_type) = upper(:PH_OBJECT_TYPE)';
        
        execute immediate sqlStatement into objectCount using upper(p_objectName), upper(p_objectType);

        if objectCount > 0 then
            return true;
        else
            return false;
        end if;
    end;

	------------------------------------------------------------------------------------------------

    function replaceNameDetailTable(p_sqlStatement varchar2, p_placeHolder varchar2, p_tableName varchar2) return varchar2
    as
    begin
        return replace(p_sqlStatement, p_placeHolder, p_tableName || '_DETAIL');
    end;
    
	------------------------------------------------------------------------------------------------

    function replaceNameMasterTable(p_sqlStatement varchar2, p_placeHolder varchar2, p_tableName varchar2) return varchar2
    as
    begin
        return replace(p_sqlStatement, p_placeHolder, p_tableName);
    end;
    
	------------------------------------------------------------------------------------------------

    -- Creates LOG tables and the sequence for the process IDs if tables or sequence don't exist
    -- For naming rules of the tables see package description
    procedure createLogTables(p_TabNameMaster varchar2)
    as
        sqlStmt varchar2(500);
    begin
        if not objectExists('SEQ_LILA_LOG', 'SEQUENCE') then
            sqlStmt := 'CREATE SEQUENCE SEQ_LILA_LOG MINVALUE 0 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 10 NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL';
            execute immediate sqlStmt;
        end if;

        if not objectExists(p_TabNameMaster, 'TABLE') then
            -- Master table
            sqlStmt := '
            create table PH_MASTER_TABLE ( 
                id number(19,0),
                process_name varchar2(100),
                process_start timestamp(6),
                process_end timestamp(6),
                last_update timestamp(6),
                steps_todo number,
                steps_done number,
                status number(2,0),
                info clob
            )';
            sqlStmt := replaceNameMasterTable(sqlStmt, PARAM_MASTER_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
        end if;

        if not objectExists(p_TabNameMaster || SUFFIX_DETAIL_NAME, 'TABLE') then
            -- Details table
            sqlStmt := '
            create table PH_DETAIL_TABLE (
                process_id number(19,0),
                no number(19,0),
                info clob,
                log_level varchar2(10),
                session_time timestamp  DEFAULT SYSTIMESTAMP,
                session_user varchar2(50),
                host_name varchar2(50),
                err_stack clob,
                err_backtrace clob,
                err_callstack clob
            )';
            sqlStmt := replaceNameDetailTable(sqlStmt, PARAM_DETAIL_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
            
        end if;
        
        if not objectExists('idx_lila_detail_master', 'INDEX') then
            sqlStmt := '
			CREATE INDEX idx_lila_detail_master
			ON PH_DETAIL_TABLE (process_id)';
            sqlStmt := replaceNameDetailTable(sqlStmt, PARAM_DETAIL_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
        end if;

        if not objectExists('idx_lila_cleanup', 'INDEX') then
            sqlStmt := '
			CREATE INDEX idx_lila_cleanup 
			ON PH_MASTER_TABLE (process_name, process_end)';
            sqlStmt := replaceNameMasterTable(sqlStmt, PARAM_MASTER_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
        end if;

    exception      
        when others then
        dbms_output.enable();
        dbms_output.put_line('Fehler...');
        dbms_output.put_line(sqlerrm);
        dbms_output.put_line(sqlStmt);
     end;
     
	------------------------------------------------------------------------------------------------

    -- Kills log entries depending to their age in days and process name.
    -- Matching of process name is not case sensitive
	procedure deleteOldLogs(p_processId number, p_processName varchar2, p_daysToKeep number) as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        t_rc SYS_REFCURSOR;
        sessionRec t_session_rec;
        processIdToDelete number(19,0);
	begin
        if p_daysToKeep is null then
            return;
        end if;

        -- find out process IDs
        sqlStatement := '
        select id from PH_MASTER_TABLE
        where process_end <= sysdate - :PH_DAYS_TO_KEEP
        and upper(process_name) = upper(:PH_PROCESS_NAME)';
        
        sessionRec := getSessionRecord(p_processId);
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);

        -- for all process IDs
        open t_rc for sqlStatement using p_daysToKeep, p_processName;
	    loop
	        fetch t_rc into processIdToDelete;
	        EXIT WHEN t_rc%NOTFOUND;
	        
	        -- delete Details first (integrity)
	        sqlStatement := 'delete from PH_DETAIL_TABLE where process_id = :1';
	        sqlStatement := replaceNameDetailTable(sqlStatement, PARAM_DETAIL_TABLE, sessionRec.tabName_master);
	        execute immediate sqlStatement USING processIdToDelete;
	
	        -- delete master
	        sqlStatement := 'delete from PH_MASTER_TABLE where id = :1';
	        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);
	        execute immediate sqlStatement USING processIdToDelete;
	    end loop;
	    close t_rc;
	    commit;

	exception
	    when others then
	        if t_rc%isopen then close t_rc; end if;
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
	end;

	------------------------------------------------------------------------------------------------

    function getProcessRecord(p_processId number) return t_process_rec
    as
        sessionRec t_session_rec;
        processRec t_process_rec;
        sqlStatement varchar2(300);
    begin
        sqlStatement := '
        select
            id,
            process_name,
            process_start,
            process_end,
            last_update,
            steps_todo,
            steps_done,
            status,
            info
        from PH_MASTER_TABLE
        where id = :PH_PROCESS_ID';
        
        sessionRec := getSessionRecord(p_processId);
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);
        execute immediate sqlStatement into processRec using p_processId;
        return processRec;
    end;


    /*
        Methods dedicated to the g_monitorList
    */
    ------------------------------------------------------------------------------------------------
    -- Hilfsfunktion (intern): Erzeugt den einheitlichen Key für den Index
    ------------------------------------------------------------------------------------------------
    function buildMonitorKey(p_processId number, p_actionName varchar2) return varchar2
    is
    begin
        return to_char(p_processId) || '_' || p_actionName;
    end;

    ------------------------------------------------------------------------------------------------
    -- Delivers a record of the monitor list by process_id and action_name
    ------------------------------------------------------------------------------------------------
    function getMonitorRecord(p_processId number, p_actionName varchar2) return t_monitor_rec
    as
        v_key     varchar2(100);
        listIndex number;
    begin
        v_key := buildMonitorKey(p_processId, p_actionName);
        
        if not v_indexSession_monitor.EXISTS(v_key) THEN
            -- Datentyp RECORD kann nicht auf IS NULL geprüft werden, 
            -- daher wird ein initialisierter Record geliefert (Felder sind NULL).
            return null; 
        end if;

        listIndex := v_indexSession_monitor(v_key);
        return g_monitorList(listIndex);
    end;

    ------------------------------------------------------------------------------------------------
    -- Update a stored record in the monitor list
    ------------------------------------------------------------------------------------------------
    procedure updateMonitorRecord(p_monitorRecord t_monitor_rec)
    as
        v_key     varchar2(100);
        listIndex number;
    begin
        v_key := buildMonitorKey(p_monitorRecord.process_id, p_monitorRecord.action_name);
        
        if v_indexSession_monitor.EXISTS(v_key) then
            listIndex := v_indexSession_monitor(v_key);
            g_monitorList(listIndex) := p_monitorRecord;
        end if;
    end;

    ------------------------------------------------------------------------------------------------
    -- Removes a record from the monitor list
    ------------------------------------------------------------------------------------------------
    procedure removeMonitor(p_processId number, p_actionName varchar2)
    as
        v_key     varchar2(100);
        v_old_idx PLS_INTEGER;
    begin
        v_key := buildMonitorKey(p_processId, p_actionName);
        
        if v_indexSession_monitor.EXISTS(v_key) then        
            v_old_idx := v_indexSession_monitor(v_key);            
            g_monitorList.DELETE(v_old_idx);            
            v_indexSession_monitor.DELETE(v_key);     
        end if;       
    end;

    ------------------------------------------------------------------------------------------------
    -- Creating and adding/updating a record in the monitor list
    ------------------------------------------------------------------------------------------------
    procedure insertMonitor (
        p_processId   number, 
        p_actionName  varchar2, 
        p_stepsDone   number, 
        p_maxSteps    number,
        p_avgDuration number
    )
    as
        v_new_idx PLS_INTEGER;
        v_key     varchar2(100);
        v_old_key varchar2(100);
    begin
        v_key := buildMonitorKey(p_processId, p_actionName);

        if g_monitorList is null then
            g_monitorList := t_monitor_tab(); 
        end if;

        -- 1. Prüfen: Existiert dieser spezifische Monitor bereits?
        if v_indexSession_monitor.EXISTS(v_key) then
            v_new_idx := v_indexSession_monitor(v_key);
        else
            -- 2. Wenn NEU: Haben wir das Limit erreicht?
            if g_monitorList.COUNT < g_max_monitor_size then
                -- Liste wächst noch bis zum Limit
                g_monitorList.extend;
                v_new_idx := g_monitorList.last;
                g_monitor_ptr := v_new_idx; -- Zeiger wandert mit
            else
                -- LIMIT ERREICHT: Round-Robin Logik
                -- Zeiger auf die nächste Position setzen (1 bis g_max_monitor_size)
                g_monitor_ptr := mod(g_monitor_ptr, g_max_monitor_size) + 1;
                v_new_idx := g_monitor_ptr;

                -- WICHTIG: Den alten Index-Eintrag entfernen, der auf diese Stelle zeigte!
                -- Wir müssen herausfinden, welcher Key vorher an dieser Stelle im Array saß
                v_old_key := buildMonitorKey(g_monitorList(v_new_idx).process_id, 
                                            g_monitorList(v_new_idx).action_name);
                v_indexSession_monitor.DELETE(v_old_key);
            end if;
        end if;

        -- 3. Daten an der ermittelten Position (v_new_idx) schreiben
        g_monitorList(v_new_idx).process_id          := p_processId;
        g_monitorList(v_new_idx).action_name         := p_actionName;
        g_monitorList(v_new_idx).steps_done          := p_stepsDone;
        g_monitorList(v_new_idx).max_steps           := p_maxSteps;
        g_monitorList(v_new_idx).avg_action_duration := p_avgDuration;

        -- 4. Neuen Index-Eintrag setzen
        v_indexSession_monitor(v_key) := v_new_idx;
    end;


    /*
		Methods dedicated to the g_sessionList
	*/

    -- Delivers a record of the internal list which belongs to the process id
    -- Return value is NULL BUT! datatype RECORD cannot be validated by IS NULL.
    -- RECORDs are always initialized.
    -- So you have to check by something like
    -- IF getSessionRecord(my_id).process_id IS NULL ...
    function getSessionRecord(p_processId number) return t_session_rec
    as
        listIndex number;
    begin
        if not v_indexSession.EXISTS(p_processId) THEN
            return null;
        end if;

        listIndex := v_indexSession(p_processId);
        return g_sessionList(listIndex);
    end;

	------------------------------------------------------------------------------------------------

    -- Set values of a stored record in the internal process list by a given record
    procedure updateSessionRecord(p_sessionRecord t_session_rec)
    as
        listIndex number;
    begin
        listIndex := v_indexSession(p_sessionRecord.process_id);
        g_sessionList(listIndex) := p_sessionRecord;
    end;

	------------------------------------------------------------------------------------------------

    -- removes a record from the internal process list
    procedure removeSession(p_processId number)
    as
        listIndex number;
        v_old_idx PLS_INTEGER;
    begin
        -- check if process exists
        if v_indexSession.EXISTS(p_processId) then        
            -- get list index
            v_old_idx := v_indexSession(p_processId);            
            -- delete from internal list
            g_sessionList.DELETE(v_old_idx);            
            -- delete index
            v_indexSession.DELETE(p_processId);     
        end if;       
    end;

	------------------------------------------------------------------------------------------------

    -- Creating and adding a new record to the process list
    procedure insertSession (p_tabName varchar2, p_processId number, p_logLevel number)
    as
        v_new_idx PLS_INTEGER;
    begin
        if g_sessionList is null then
                g_sessionList := t_session_tab(); 
        end if;

        if getSessionRecord(p_processId).process_id is null then
            -- neuer Datensatz
            g_sessionList.extend;
            v_new_idx := g_sessionList.last;
        else
            v_new_idx := v_indexSession(p_processId);
        end if;

        g_sessionList(v_new_idx).process_id      := p_processId;
        g_sessionList(v_new_idx).counter_details := 0;
        g_sessionList(v_new_idx).log_level       := p_logLevel;
        g_sessionList(v_new_idx).tabName_master  := p_tabName;

        v_indexSession(p_processId) := v_new_idx;
    end;

	------------------------------------------------------------------------------------------------

    -- Whatever you want
    function test(p_processId number) return varchar2
    as
        sessionRec t_session_rec;
    begin
		-- example:
		-- select pck_logging.test(0) from dual;
        sessionRec := getSessionRecord(p_processId);        
        return 'prefix: ' ||sessionRec.tabName_master || '; counter: ' || nvl(sessionRec.counter_details, 0) || '; log_level: ' || nvl(sessionRec.log_level, 0);
    end;

	------------------------------------------------------------------------------------------------

	/*
		Internal methods dedicated to logging
	*/

    -- Writes a record to the details log table and marks it with the log level
    procedure write_detail(p_processId number, p_stepInfo varchar2, p_logLevel number)
    as 
        pragma autonomous_transaction;
        sqlStatement varchar2(2000);
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sessionRec.counter_details := sessionRec.counter_details +1;
        updateSessionRecord(sessionRec);
        
        sqlStatement := '
        insert into PH_DETAIL_TABLE (
            process_id, no, info, log_level,
            session_user, host_name
        )
        values (
            :PH_PROCESS_ID, :PH_COUNTER_DETAILS, :PH_STEP_INFO, :PH_LOG_LEVEL,
            :PH_SESSION_USER, :PH_HOST_NAME
        )';
        sqlStatement := replaceNameDetailTable(sqlStatement, PARAM_DETAIL_TABLE, sessionRec.tabName_master);
        execute immediate sqlStatement using p_processId, sessionRec.counter_details, p_stepInfo, p_logLevel,
            SYS_CONTEXT('USERENV','SESSION_USER'), SYS_CONTEXT('USERENV','HOST');
        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden

    end;

	------------------------------------------------------------------------------------------------

    -- Writes a record to the details log table with debugging infos
    -- Log level of the record is given by p_logLevel
    procedure write_debug_info(p_processId number, p_stepInfo varchar2, p_logLevel number)
    as 
        pragma autonomous_transaction;
        sqlStatement varchar2(4000);
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sessionRec.counter_details := sessionRec.counter_details +1;
        updateSessionRecord(sessionRec);

        sqlStatement := '
        insert into PH_DETAIL_TABLE (
            process_id, no, info, log_level,
            session_user, host_name, err_callstack
        )
        values (
            :PH_PROCESS_ID, :PH_COUNTER_DETAILS, :PH_STEP_INFO, :PH_LOG_LEVEL,
            :PH_SESSION_USER, :PH_HOST_NAME, :PH_ERR_CALLSTACK
        )';
        sqlStatement := replaceNameDetailTable(sqlStatement, PARAM_DETAIL_TABLE, sessionRec.tabName_master);
        execute immediate sqlStatement using p_processId, sessionRec.counter_details, p_stepInfo, p_logLevel,
            SYS_CONTEXT('USERENV','SESSION_USER'), SYS_CONTEXT('USERENV','HOST'), DBMS_UTILITY.FORMAT_CALL_STACK;         
        commit;
	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
    end;

	------------------------------------------------------------------------------------------------

    -- Writes a record to the details log table with error infos
    -- Log level of the record is given by p_logLevel
    procedure write_error_stack(p_processId number, p_stepInfo varchar2, p_logLevel number)
    as 
        pragma autonomous_transaction;
        sqlStatement varchar2(4000);
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sessionRec.counter_details := sessionRec.counter_details +1;
        updateSessionRecord(sessionRec);

        sqlStatement := '
        insert into PH_DETAIL_TABLE (
            process_id, no, info, log_level,
            session_user, host_name, err_stack, err_backtrace, err_callstack
        )
        values (
            :PH_PROCESS_ID, :PH_COUNTER_DETAILS, :PH_STEP_INFO, :PH_LOG_LEVEL, 
            :PH_SESSION_USER, :PH_HOST_NAME, :PH_ERR_STACK, :PH_ERR_BACKTRACE, :PH_ERR_CALLSTACK
        )';
        sqlStatement := replaceNameDetailTable(sqlStatement, PARAM_DETAIL_TABLE, sessionRec.tabName_master);
        execute immediate sqlStatement using p_processId, sessionRec.counter_details, p_stepInfo, p_logLevel,
            SYS_CONTEXT('USERENV', 'SESSION_USER'), SYS_CONTEXT('USERENV','HOST'),
            DBMS_UTILITY.FORMAT_ERROR_STACK, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, DBMS_UTILITY.FORMAT_CALL_STACK;
        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
    end;


    /*
		Public functions and procedures
    */

    -- Used by external Procedure to write a new log entry with log level DEBUG
    -- Details are adjusted to the debug level
    procedure DEBUG(p_processId number, p_stepInfo varchar2)
    as
    begin
        if logLevelDebug <= getSessionRecord(p_processId).log_level then
            write_debug_info(p_processId, p_stepInfo, logLevelDebug);
        end if;
    end;

	------------------------------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level INFO
    -- Details are adjusted to the info level
    procedure INFO(p_processId number, p_stepInfo varchar2)
    as
    begin
        if logLevelInfo <= getSessionRecord(p_processId).log_level then
            log_detail(p_processId, p_stepInfo, logLevelInfo);
        end if;
    end;

	------------------------------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level ERROR
    -- Details are adjusted to the error level
    procedure ERROR(p_processId number, p_stepInfo varchar2)
    as
    begin
        if logLevelError <= getSessionRecord(p_processId).log_level then
            write_error_stack(p_processId, p_stepInfo, logLevelError);
        end if;
    end;

	------------------------------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level WARN
    -- Details are adjusted to the warn level
    procedure WARN(p_processId number, p_stepInfo varchar2)
    as
    begin
        if logLevelWarn <= getSessionRecord(p_processId).log_level then
            log_detail(p_processId, p_stepInfo, logLevelWarn);
        end if;
    end;

	------------------------------------------------------------------------------------------------

    -- Writes data to the log detail table.
    -- Enables independency of log levels to the calling script.
    procedure LOG_DETAIL(p_processId number, p_stepInfo varchar2, p_logLevel PLS_INTEGER)
    as
    begin
        write_detail(p_processId, p_stepInfo, p_logLevel);
    end;

	------------------------------------------------------------------------------------------------

    -- Updates the status of a log entry in the main log table.
    procedure SET_PROCESS_STATUS(p_processId number, p_status PLS_INTEGER)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sqlStatement := '
        update PH_MASTER_TABLE
        set status = :PH_STATUS,
            last_update = current_timestamp
        where id = :PH_PROCESS_ID';  
        
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);        
        execute immediate sqlStatement using p_status, p_processId;
        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
    end;

	------------------------------------------------------------------------------------------------

    -- Updates the status and the info field of a log entry in the main log table.
    procedure SET_PROCESS_STATUS(p_processId number, p_status PLS_INTEGER, p_processInfo varchar2)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sqlStatement := '
        update PH_MASTER_TABLE
        set status = :PH_STATUS,
            info = :PH_PROCESS_INFO,
            last_update = current_timestamp
        where id = :PH_PROCESS_ID';
        
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);        
        execute immediate sqlStatement using p_status, p_processInfo, p_processId;
        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
    end;

	------------------------------------------------------------------------------------------------
    
    procedure SET_STEPS_TODO(p_processId number, p_stepsToDo number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sqlStatement := '
        update PH_MASTER_TABLE
        set steps_todo = :PH_STEPS_TODO,
            last_update = current_timestamp
        where id = :PH_PROCESS_ID';   
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);        
        execute immediate sqlStatement using p_stepsToDo, p_processId;
        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
    end;

	------------------------------------------------------------------------------------------------
    
    procedure SET_STEPS_DONE(p_processId number, p_stepsDone number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sqlStatement := '
        update PH_MASTER_TABLE
        set steps_done = :PH_STEPS_DONE,
            last_update = current_timestamp
        where id = :PH_PROCESS_ID';   
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);        
        execute immediate sqlStatement using p_stepsDone, p_processId;
        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
    end;
	------------------------------------------------------------------------------------------------
    
    procedure STEP_DONE(p_processId number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        lStepCounter number;
        sessionRec t_session_rec;
    begin
        sessionRec := getSessionRecord(p_processId);
        sqlStatement := '
        select steps_done
        from PH_MASTER_TABLE
        where id = :PH_PROCESS_ID';   
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);        
        execute immediate sqlStatement into lStepCounter using p_processId;
        lStepCounter := nvl(lStepCounter, 0) +1;
        set_steps_done(p_processId, lStepCounter);
    end;
    
	------------------------------------------------------------------------------------------------

    FUNCTION GET_STEPS_DONE(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        return getProcessRecord(p_processId).steps_done;
    end;

	------------------------------------------------------------------------------------------------

    FUNCTION GET_STEPS_TODO(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        return getProcessRecord(p_processId).steps_todo;
    end;

	------------------------------------------------------------------------------------------------
    
    function GET_PROCESS_START(p_processId NUMBER) return timestamp
    as
    begin
        return getProcessRecord(p_processId).process_start;
    end;
    
	------------------------------------------------------------------------------------------------
    
    function GET_PROCESS_END(p_processId NUMBER) return timestamp
    as
    begin
        return getProcessRecord(p_processId).process_end;
    end;

	------------------------------------------------------------------------------------------------

    function GET_PROCESS_STATUS(p_processId number) return PLS_INTEGER
    as 
    begin
        return getProcessRecord(p_processId).status;
    end;

	------------------------------------------------------------------------------------------------

    function GET_PROCESS_INFO(p_processId number) return varchar2
    as 
    begin
        return getProcessRecord(p_processId).info;
    end;

	------------------------------------------------------------------------------------------------
    
    PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_processInfo VARCHAR2, p_status PLS_INTEGER)
    as
    begin
        close_session(
            p_processId   => p_processId, 
            p_stepsToDo   => null, 
            p_stepsDone   => null, 
            p_processInfo => p_processInfo, 
            p_status      => p_status
        );
    end;
    
    PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_stepsDone NUMBER, p_processInfo VARCHAR2, p_status PLS_INTEGER)
    as
    begin
        close_session(
            p_processId   => p_processId, 
            p_stepsToDo   => null, 
            p_stepsDone   => p_stepsDone, 
            p_processInfo => p_processInfo, 
            p_status      => p_status
        );
    end;


    
    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure CLOSE_SESSION(p_processId number)
    as
--        pragma autonomous_transaction;
--        sqlStatement varchar2(500);
--        sessionRec t_session_rec;
    begin
        close_session(
            p_processId   => p_processId, 
            p_stepsToDo   => null, 
            p_stepsDone   => null, 
            p_processInfo => null, 
            p_status      => null
        );
        
        /*
        sessionRec := getSessionRecord(p_processId);
        if getSessionRecord(p_processId).process_id is null then
            return;
        end if;

		if getSessionRecord(p_processId).log_level > logLevelSilent then
	        sqlStatement := '
	        update PH_MASTER_TABLE
	        set process_end = current_timestamp,
                last_update = current_timestamp
	        where id = :PH_PROCESS_ID';
            sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);
	        execute immediate sqlStatement using p_processId;
	        commit;
        end if;
        g_sessionList.delete(p_processId);

		exception
		    when others then
		        if t_rc%isopen then close t_rc; end if;
		        rollback; -- Auch im Fehlerfall die Transaktion beenden

        */
    end;

	------------------------------------------------------------------------------------------------

    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure CLOSE_SESSION(p_processId number, p_stepsToDo number, p_stepsDone number, p_processInfo varchar2, p_status PLS_INTEGER)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        sessionRec t_session_rec;
        sqlCursor number := null;
        updateCount number;
    begin
        sessionRec := getSessionRecord(p_processId);
        if sessionRec.process_id is null then
            return;
        end if;

		if sessionRec.log_level > logLevelSilent then
	        sqlStatement := '
	        update PH_MASTER_TABLE
	        set process_end = current_timestamp,
                last_update = current_timestamp';

            if p_stepsDone is not null then
                sqlStatement := sqlStatement || ', steps_done = :PH_STEPS_DONE';
            end if;
            if p_stepsToDo is not null then
                sqlStatement := sqlStatement || ', steps_todo = :PH_STEPS_TO_DO';
            end if;
            if p_processInfo is not null then
                sqlStatement := sqlStatement || ', info = :PH_PROCESS_INFO';
            end if;     
            if p_status is not null then
                sqlStatement := sqlStatement || ', status = :PH_STATUS';
            end if;     
            
            sqlStatement := sqlStatement || ' where id = :PH_PROCESS_ID'; 
            sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);
            
            -- due to the variable number of parameters using dbms_sql
            sqlCursor := DBMS_SQL.OPEN_CURSOR;
            DBMS_SQL.PARSE(sqlCursor, sqlStatement, DBMS_SQL.NATIVE);
            DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_PROCESS_ID', p_processId);

            if p_stepsDone is not null then
                DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_STEPS_DONE', p_stepsDone);
            end if;
            if p_stepsToDo is not null then
                DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_STEPS_TO_DO', p_stepsToDo);
            end if;
            if p_processInfo is not null then
                DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_PROCESS_INFO', p_processInfo);
            end if;     
            if p_status is not null then
                DBMS_SQL.BIND_VARIABLE(sqlCursor, ':PH_STATUS', p_status);
            end if;     

            updateCount := DBMS_SQL.EXECUTE(sqlCursor);
            DBMS_SQL.CLOSE_CURSOR(sqlCursor);
        end if;
        commit;
        
        -- Eintrag aus internem Speicher entfernen
        g_sessionList.delete(p_processId);
if v_indexSession.EXISTS(p_processId) then
    g_sessionList.delete(v_indexSession(p_processId));
    v_indexSession.delete(p_processId); -- Auch den Index-Eintrag entfernen!
end if;
        
    EXCEPTION
        WHEN OTHERS THEN
            IF DBMS_SQL.IS_OPEN(sqlCursor) THEN
                DBMS_SQL.CLOSE_CURSOR(sqlCursor);
            END IF;
            sqlCursor := null;
			rollback;
    end;

	------------------------------------------------------------------------------------------------

    function NEW_SESSION(p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_tabNameMaster VARCHAR2 DEFAULT 'LILA_LOG') return number
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(600);
        pProcessId number(19,0);
    begin
       -- If silent log mode don't do anything
        if p_logLevel > logLevelSilent then
	        -- Sicherstellen, dass die LOG-Tabellen existieren
	        createLogTables(p_TabNameMaster);
        end if;

        select seq_lila_log.nextVal into pProcessId from dual;
        insertSession (p_TabNameMaster, pProcessId, p_logLevel);

		if p_logLevel > logLevelSilent and p_daysToKeep is not null then
	        deleteOldLogs(pProcessId, upper(trim(p_processName)), p_daysToKeep);

	        sqlStatement := '
	        insert into PH_MASTER_TABLE (
	            id,
	            process_name,
	            process_start,
				last_update,
	            process_end,
	            steps_todo,
	            steps_done,
	            status,
	            info
	        )
	        values (
	            :PH_PROCESS_ID, 
	            :PH_PROCESS_NAME, 
	            current_timestamp,
				current_timestamp,
                null,
	            :PH_STEPS_TO_DO, 
	            null,
	            null,
	            ''START''
            )';
            sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, p_TabNameMaster);
	        execute immediate sqlStatement using pProcessId, p_processName, p_stepsToDo;     
	        commit;
        end if;
        return pProcessId;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
    end;

	------------------------------------------------------------------------------------------------

    function NEW_SESSION(p_processName varchar2, p_logLevel PLS_INTEGER, p_tabNameMaster varchar2 default 'LILA_LOG') return number
    as
    begin
        return new_session(
            p_processName   => p_processName,
            p_logLevel      => p_logLevel, 
            p_daysToKeep    => null, 
            p_stepsToDo     => null, 
            p_tabNameMaster => p_tabNameMaster);
    end;


    -- Opens/starts a new logging session.
    -- The returned process id must be stored within the calling procedure because it is the reference
    -- which is recommended for all following actions (e.g. CLOSE_SESSION, DEBUG, SET_PROCESS_STATUS).
    function NEW_SESSION(p_processName varchar2, p_logLevel PLS_INTEGER, p_daysToKeep number, p_tabNameMaster varchar2 default 'LILA_LOG') return number
    as
--        pragma autonomous_transaction;
--        sqlStatement varchar2(600);
--        pProcessId number(19,0);
    begin
        return new_session(
            p_processName   => p_processName,
            p_logLevel      => p_logLevel, 
            p_daysToKeep    => p_daysToKeep, 
            p_stepsToDo     => null, 
            p_tabNameMaster => p_tabNameMaster);

    /*    
        -- If silent log mode don't do anything
        if p_logLevel > logLevelSilent then
	        -- Sicherstellen, dass die LOG-Tabellen existieren
	        createLogTables(p_TabNameMaster);
        end if;

        select seq_lila_log.nextVal into pProcessId from dual;
        insertSession (p_TabNameMaster, pProcessId, p_logLevel);

		if p_logLevel > logLevelSilent and p_daysToKeep is not null then
	        deleteOldLogs(pProcessId, upper(trim(p_processName)), p_daysToKeep);

	        sqlStatement := '
	        insert into PH_MASTER_TABLE (
	            id,
	            process_name,
	            process_start,
				last_update,
	            process_end,
	            steps_todo,
	            steps_done,
	            status,
	            info
	        )
            values (
	            :PH_PROCESS_ID, 
	            :PH_PROCESS_NAME, 
	            current_timestamp,
	            current_timestamp,
	            null, 
	            null,
	            null, 
	            0,
	            ''START''
            )';
            sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, p_TabNameMaster);
	        execute immediate sqlStatement using pProcessId, p_processName;     

	        commit;
        end if;
        return pProcessId;

		exception
		    when others then
		        if t_rc%isopen then close t_rc; end if;
		        rollback; -- Auch im Fehlerfall die Transaktion beenden

    */
    end;
    
	------------------------------------------------------------------------------------------------

    PROCEDURE IS_ALIVE
    as
        pProcessName number(19,0);
    begin
        pProcessName := new_session('LILA Life Check', logLevelDebug);
        debug(pProcessName, 'First Message of LILA');
        close_session(pProcessName, 1, 1, 'OK', 1);
    end;

END LILA;
