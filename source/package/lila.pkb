create or replace PACKAGE BODY LILA AS

    -- Record representing the internal session
    TYPE t_session_rec IS RECORD (
        process_id      NUMBER(19,0),
        counter_details NUMBER := 0,
        log_level       NUMBER := 0,
        tabName_prefix  VARCHAR2(100)
    );

    TYPE t_process_rec IS RECORD (
        id      NUMBER(19,0),
        process_name varchar2(100),
        process_start TIMESTAMP,
        process_end TIMESTAMP,
        last_update TIMESTAMP,
        steps_todo NUMBER,
        steps_done NUMBER,
        status NUMBER,
        info CLOB

    );

    -- Table for several processes
    TYPE t_session_tab IS TABLE OF t_session_rec;
    g_sessionList t_session_tab := null;

    -- Index for entries in process list
    TYPE t_search_idx IS TABLE OF PLS_INTEGER INDEX BY BINARY_INTEGER;
    v_index t_search_idx;

    -- Placeholders for Statements
    PH_LILA_TABLE_NAME constant varchar2(30) := 'PH_LILA_TABLE_NAME';
    PH_LILA_DETAIL_TABLE_NAME constant varchar2(30) := 'PH_LILA_DETAIL_TABLE_NAME';
    PH_PROCESS_NAME constant varchar2(30) := 'PH_PROCESS_NAME';
    PH_PROCESS_INFO constant varchar2(30) := 'PH_PROCESS_INFO';
    PH_COUNTER_DETAILS constant varchar2(30) := 'PH_COUNTER_DETAILS';
    PH_STEP_INFO constant varchar2(30) := 'PH_STEP_INFO';
    PH_PROCESS_ID constant varchar2(30) := 'PH_PROCESS_ID';
    PH_STATUS constant varchar2(30) := 'PH_STATUS';
    PH_STEPS_TO_DO constant varchar2(30) := 'PH_STEPS_TO_DO';
    PH_STEPS_DONE constant varchar2(30) := 'PH_STEPS_DONE';
    PH_LOG_LEVEL constant varchar2(30) := 'PH_LOG_LEVEL';
    PH_SESSION_USER constant varchar2(30) := 'PH_SESSION_USER';
    PH_HOST_NAME constant varchar2(30) := 'PH_HOST_NAME';
    PH_ERR_CALLSTACK constant varchar2(30) := 'PH_ERR_CALLSTACK';
    PH_ERR_STACK constant varchar2(30) := 'PH_ERR_STACK';
    PH_ERR_BACKTRACE constant varchar2(30) := 'PH_ERR_BACKTRACE';


    cr constant varchar2(2) := chr(13) || chr(10);
    function getSessionRecord(p_processId number) return t_session_rec;

    /*
        Internal methods.
        Internal methods are written in lowercase and camelCase
    */    

    -- Delivers number logLevel as string
    function getLogLevelAsText(p_logLevelNumber number) return varchar2
    as
    begin
        case p_logLevelNumber
            when logLevelSilent then return 'SILENT';
            when logLevelError then return 'ERROR';
            when logLevelInfo then return 'INFO';
            when logLevelDebug then return 'DEBUG';
            else return 'UNKNOWN';
        end case;
    end;

	------------------------------------------------------------------------------------------------

    -- Checks if a table exists physically
    function tableExists(p_TabName varchar2) return boolean
    as
        tableCount number;
    begin
        select count(*)
        into tableCount
        from user_tables
        where table_name = upper(p_tabName);

        if tableCount > 0 then
            return true;
        else
            return false;
        end if;
    end;

	------------------------------------------------------------------------------------------------

    -- Checks if a database sequence exists
    function sequenceExists(p_SequenceName varchar2) return boolean
    as
        sequenceCount number;
    begin
        select count(*)
        into sequenceCount
        from user_objects
        where object_name = upper(p_SequenceName)
        and   object_type = 'SEQUENCE';

        if sequenceCount > 0 then
            return true;
        else
            return false;
        end if;    end;

	------------------------------------------------------------------------------------------------

    -- Creates LOG tables and the sequence for the process IDs if tables or sequence don't exist
    -- For naming rules of the tables see package description
    procedure createLogTables(p_TabNamePrefix varchar2)
    as
        sqlStmt varchar2(500);
    begin
        if not sequenceExists('SEQ_LILA_LOG') then
            sqlStmt := 'CREATE SEQUENCE SEQ_LILA_LOG MINVALUE 0 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 10 NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL';
            execute immediate sqlStmt;
        end if;

        if not tableExists(p_TabNamePrefix) then
            -- Master table
            sqlStmt := '
            create table NEW_TABLE_NAME ( 
                id number(19,0),
                process_name varchar2(100),
                process_start timestamp(6),
                process_end timestamp(6),
                last_update timestamp(6),
                steps_todo NUMBER,
                steps_done number,
                status number(1,0),
                info clob
            )';
            sqlStmt := replace(sqlStmt, 'NEW_TABLE_NAME', p_TabNamePrefix);
            execute immediate sqlStmt;

            sqlStmt := '
			CREATE INDEX idx_lila_cleanup 
			ON NEW_TABLE_NAME (process_name, process_end)';
            sqlStmt := replace(sqlStmt, 'NEW_TABLE_NAME', p_TabNamePrefix);
            execute immediate sqlStmt;


            -- Details table
            sqlStmt := '
            create table NEW_DETAIL_TABLE_NAME (
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
            sqlStmt := replace(sqlStmt, 'NEW_DETAIL_TABLE_NAME', p_TabNamePrefix || '_DETAIL');
            execute immediate sqlStmt;
            
            sqlStmt := '
			CREATE INDEX idx_lila_detail_master
			ON NEW_DETAIL_TABLE_NAME (process_id)';
            sqlStmt := replace(sqlStmt, 'NEW_DETAIL_TABLE_NAME', p_TabNamePrefix || '_DETAIL');
            execute immediate sqlStmt;
        end if;

    exception      
        when others then
        dbms_output.enable();
        dbms_output.put_line('Fehler...');
        dbms_output.put_line(sqlerrm);
        dbms_output.put_line(sqlStmt);
     end;

	------------------------------------------------------------------------------------------------

    -- Simplifies the handling of SQL-Statements.
    -- Enables the usage of placeholders within the statetements which are replaced here.
    -- The placeholders and it's values are specific and hard related to each other.
    -- Some values are given by the function header, some by the record which belongs to the process.
    function replacePlaceHolders(pProcessId number, pStringToReplace varchar2, pProcessName varchar2, pStatus number, pProcessInfo varchar2, 
        pStepInfo varchar2, pStepsToDo number, pStepsDone number, pLogLevel number) return varchar2
    as
        replacedString varchar2(4000) := pStringToReplace;
        processRecord t_session_rec;
    begin
        -- find record which relates to the process id
        processRecord := getSessionRecord(pProcessId);
        
        /*
            später tauschen, wenn der Rest funktioniert
        replacedString := replace(
            replace(
                replace(
                    replace(
                        replace(
                            replace(
                                replace(
                                    replace(
                                        replace(
                                            replace(
                                                replace(
                                                    replace(
                                                        replace(
                                                            replace(
                                                                replace(
                                                                    replace(
                                                                        replacedString, PH_LILA_TABLE_NAME, processRecord.tabName_prefix
                                                                    ), PH_LILA_DETAIL_TABLE_NAME,  processRecord.tabName_prefix || '_DETAIL'
                                                                ), PH_PROCESS_NAME, pProcessName
                                                            ), PH_PROCESS_INFO, pProcessInfo
                                                        ), PH_COUNTER_DETAILS, processRecord.counter_details
                                                    ), PH_STEP_INFO, pStepInfo
                                                ), PH_PROCESS_ID, pProcessId
                                            ), PH_STATUS, pStatus
                                        ), PH_STEPS_TO_DO, pStepsToDo
                                    ), PH_STEPS_DONE, pStepsDone
                                ), PH_LOG_LEVEL, getLogLevelAsText(pLogLevel)
                            ), PH_SESSION_USER, SYS_CONTEXT('USERENV','SESSION_USER')
                        ), PH_HOST_NAME, SYS_CONTEXT('USERENV','HOST')
                    ), PH_ERR_CALLSTACK, DBMS_UTILITY.FORMAT_CALL_STACK
                ), PH_ERR_STACK, DBMS_UTILITY.FORMAT_ERROR_STACK
            ), PH_ERR_BACKTRACE, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE
        );
        */

        replacedString := replace(replacedString, PH_LILA_TABLE_NAME, processRecord.tabName_prefix);
        replacedString := replace(replacedString, PH_LILA_DETAIL_TABLE_NAME,  processRecord.tabName_prefix || '_DETAIL');
        replacedString := replace(replacedString, PH_PROCESS_NAME, pProcessName);
        replacedString := replace(replacedString, PH_PROCESS_INFO, pProcessInfo);
        replacedString := replace(replacedString, PH_COUNTER_DETAILS, processRecord.counter_details);
        replacedString := replace(replacedString, PH_STEP_INFO, pStepInfo);
        replacedString := replace(replacedString, PH_PROCESS_ID, pProcessId);
        replacedString := replace(replacedString, PH_STATUS, pStatus);
        replacedString := replace(replacedString, PH_STEPS_TO_DO, pStepsToDo);
        replacedString := replace(replacedString, PH_STEPS_DONE, pStepsDone);
        replacedString := replace(replacedString, PH_LOG_LEVEL, getLogLevelAsText(pLogLevel));
        replacedString := replace(replacedString, PH_SESSION_USER, SYS_CONTEXT('USERENV','SESSION_USER'));
        replacedString := replace(replacedString, PH_HOST_NAME, SYS_CONTEXT('USERENV','HOST'));
        replacedString := replace(replacedString, PH_ERR_CALLSTACK, DBMS_UTILITY.FORMAT_CALL_STACK);
        replacedString := replace(replacedString, PH_ERR_STACK, DBMS_UTILITY.FORMAT_ERROR_STACK);
        replacedString := replace(replacedString, PH_ERR_BACKTRACE, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);

        return replacedString;
    end;

	------------------------------------------------------------------------------------------------

    -- Kills log entries depending to their age in days and process name.
    -- Matching of process name is not case sensitive
    procedure  deleteOldLogs(p_processId number, p_processName varchar2, p_daysToKeep number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        t_rc SYS_REFCURSOR;
        pProcessIdToDelete number;
    begin
        if p_daysToKeep is null then
            return;
        end if;

        -- find out process IDs
        sqlStatement := '
        select id from PH_LILA_TABLE_NAME
        where process_end <= sysdate - PH_DAYS_TO_KEEP
        and upper(process_name) = upper(''PH_PROCESS_NAME'')';
        
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, p_processName, null, null, null, null, null, null);
        sqlStatement := replace(sqlStatement, 'PH_DAYS_TO_KEEP', to_char(p_daysToKeep));

        -- for all process IDs
        open t_rc for sqlStatement;
        loop
            fetch t_rc into pProcessIdToDelete;
            EXIT WHEN t_rc%NOTFOUND;

            -- kill entries in main log table
            sqlStatement := '
            delete from PH_LILA_TABLE_NAME
            where id = PH_ID';

            sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, null, null, null, null);
            sqlStatement := replace(sqlStatement, 'PH_ID', to_char(pProcessIdToDelete));
            execute immediate sqlStatement;

            -- kill entries from log details table
            sqlStatement := '
            delete from PH_LILA_DETAIL_TABLE_NAME
            where process_id = PH_ID';
            sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, null, null, null, null);
            sqlStatement := replace(sqlStatement, 'PH_ID', to_char(pProcessIdToDelete));
            execute immediate sqlStatement;

        end loop;
        close t_rc;  
        commit;
    end;

	------------------------------------------------------------------------------------------------

    function getProcessRecord(p_processId number) return t_process_rec
    as
        lProcessRec t_process_rec;
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
        from PH_LILA_TABLE_NAME
        where id = PH_PROCESS_ID';
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, null, null, null, null);
        execute immediate sqlStatement into lProcessRec;
        return lProcessRec;
    end;

	------------------------------------------------------------------------------------------------

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
        if not v_index.EXISTS(p_processId) THEN
            return null;
        end if;

        listIndex := v_index(p_processId);
        return g_sessionList(listIndex);
    end;

	------------------------------------------------------------------------------------------------

    -- Set values of a stored record in the internal process list by a given record
    procedure updateSessionRecord(p_sessionRecord t_session_rec)
    as
        listIndex number;
    begin
        listIndex := v_index(p_sessionRecord.process_id);
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
        if v_index.EXISTS(p_processId) then        
            -- get list index
            v_old_idx := v_index(p_processId);            
            -- delete from internal list
            g_sessionList.DELETE(v_old_idx);            
            -- delete index
            v_index.DELETE(p_processId);     
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
            v_new_idx := v_index(p_processId);
        end if;

        g_sessionList(v_new_idx).process_id      := p_processId;
        g_sessionList(v_new_idx).counter_details := 0;
        g_sessionList(v_new_idx).log_level       := p_logLevel;
        g_sessionList(v_new_idx).tabName_prefix  := p_tabName;

        v_index(p_processId) := v_new_idx;
    end;

	------------------------------------------------------------------------------------------------

    -- Whatever you want
    function test(p_processId number) return varchar2
    as
        processRecord t_session_rec;
    begin
		-- example:
		-- select pck_logging.test(0) from dual;
        processRecord := getSessionRecord(p_processId);        
        return 'prefix: ' ||processRecord.tabName_prefix || '; counter: ' || nvl(processRecord.counter_details, 0) || '; log_level: ' || nvl(processRecord.log_level, 0);
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
        processRecord t_session_rec;
    begin
        processRecord := getSessionRecord(p_processId);
        processRecord.counter_details := processRecord.counter_details +1;
        updateSessionRecord(processRecord);

        sqlStatement := '
        insert into PH_LILA_DETAIL_TABLE_NAME (
            process_id, no, info, log_level,
            session_user, host_name
        )
        values (
            PH_PROCESS_ID, PH_COUNTER_DETAILS, ''PH_STEP_INFO'', ''PH_LOG_LEVEL'',
            ''PH_SESSION_USER'', ''PH_HOST_NAME''
        )';
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, p_stepInfo, null, null, p_logLevel);
        execute immediate sqlStatement;
        commit;
    end;

	------------------------------------------------------------------------------------------------

    -- Writes a record to the details log table with debugging infos
    -- Log level of the record is given by p_logLevel
    procedure write_debug_info(p_processId number, p_stepInfo varchar2, p_logLevel number)
    as 
        pragma autonomous_transaction;
        sqlStatement varchar2(4000);
        processRecord t_session_rec;
    begin
        processRecord := getSessionRecord(p_processId);
        processRecord.counter_details := processRecord.counter_details +1;
        updateSessionRecord(processRecord);

        sqlStatement := '
        insert into PH_LILA_DETAIL_TABLE_NAME (
            process_id, no, info, log_level,
            session_user, host_name, err_callstack
        )
        values (
            PH_PROCESS_ID, PH_COUNTER_DETAILS, ''PH_STEP_INFO'', ''PH_LOG_LEVEL'',
            ''PH_SESSION_USER'', ''PH_HOST_NAME'', ''PH_ERR_CALLSTACK''
        )';
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, p_stepInfo, null, null, p_logLevel);
        execute immediate sqlStatement;
        commit;
    end;

	------------------------------------------------------------------------------------------------

    -- Writes a record to the details log table with error infos
    -- Log level of the record is given by p_logLevel
    procedure write_error_stack(p_processId number, p_stepInfo varchar2, p_logLevel number)
    as 
        pragma autonomous_transaction;
        sqlStatement varchar2(4000);
        processRecord t_session_rec;
    begin
        processRecord := getSessionRecord(p_processId);
        processRecord.counter_details := processRecord.counter_details +1;
        updateSessionRecord(processRecord);

        sqlStatement := '
        insert into PH_LILA_DETAIL_TABLE_NAME (
            process_id, no, info, log_level,
            session_user, host_name, err_stack, err_backtrace, err_callstack
        )
        values (
            PH_PROCESS_ID, PH_COUNTER_DETAILS, ''PH_STEP_INFO'', ''PH_LOG_LEVEL'', 
            ''PH_SESSION_USER'', ''PH_HOST_NAME'', ''PH_ERR_STACK'', ''PH_ERR_BACKTRACE'', ''PH_ERR_CALLSTACK''
        )';
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, p_stepInfo, null, null, p_logLevel);

        execute immediate sqlStatement;
        commit;
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
    procedure LOG_DETAIL(p_processId number, p_stepInfo varchar2, p_logLevel number)
    as
    begin
        write_detail(p_processId, p_stepInfo, p_logLevel);
    end;

	------------------------------------------------------------------------------------------------

    -- Updates the status of a log entry in the main log table.
    procedure SET_PROCESS_STATUS(p_processId number, p_status number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
    begin
        sqlStatement := '
        update PH_LILA_TABLE_NAME
        set status = PH_STATUS,
            last_update = current_timestamp
        where id = PH_PROCESS_ID';   
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, p_status, null, null, null, null, null);
        execute immediate sqlStatement;
        commit;
    end;

	------------------------------------------------------------------------------------------------

    -- Updates the status and the info field of a log entry in the main log table.
    procedure SET_PROCESS_STATUS(p_processId number, p_status number, p_processInfo varchar2)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
    begin
        sqlStatement := '
        update PH_LILA_TABLE_NAME
        set status = PH_STATUS,
            info = ''PH_PROCESS_INFO'',
            last_update = current_timestamp
        where id = PH_PROCESS_ID';
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, p_status, p_processInfo, null, null, null, null);
        execute immediate sqlStatement;
        commit;
    end;

	------------------------------------------------------------------------------------------------
    
    procedure SET_STEPS_TODO(p_processId number, p_stepsToDo number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
    begin
        sqlStatement := '
        update PH_LILA_TABLE_NAME
        set steps_todo = PH_STEPS_TODO,
            last_update = current_timestamp
        where id = PH_PROCESS_ID';   
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, null, null, null, null);
        sqlStatement := replace(sqlStatement, 'PH_STEPS_TODO', to_char(p_stepsToDo));
        execute immediate sqlStatement;
        commit;
    end;

	------------------------------------------------------------------------------------------------
    
    procedure SET_STEPS_DONE(p_processId number, p_stepsDone number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
    begin
        sqlStatement := '
        update PH_LILA_TABLE_NAME
        set steps_done = PH_STEPS_DONE,
            last_update = current_timestamp
        where id = PH_PROCESS_ID';   
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, null, null, p_stepsDone, null);
        execute immediate sqlStatement;
        commit;
    end;
	------------------------------------------------------------------------------------------------
    
    procedure STEP_DONE(p_processId number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        lStepCounter number;
    begin
        sqlStatement := '
        select steps_done
        from PH_LILA_TABLE_NAME
        where id = PH_PROCESS_ID';   
        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, null, null, null, null);
        
        execute immediate sqlStatement into lStepCounter;
        lStepCounter := nvl(lStepCounter, 0) +1;
        set_steps_done(p_processId, lStepCounter);
    end;
    
	------------------------------------------------------------------------------------------------

    function GET_STEPS_DONE(p_processId NUMBER) return number
    as
    begin
        return getProcessRecord(p_processId).steps_done;
    end;

	------------------------------------------------------------------------------------------------

    function GET_STEPS_TODO(p_processId NUMBER) return number
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

    function GET_PROCESS_STATUS(p_processId number) return number
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
    
    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure CLOSE_SESSION(p_processId number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
    begin
        if getSessionRecord(p_processId).process_id is null then
            return;
        end if;

		if getSessionRecord(p_processId).log_level > logLevelSilent then
	        sqlStatement := '
	        update PH_LILA_TABLE_NAME
	        set process_end = current_timestamp,
                last_update = current_timestamp
	        where id = PH_PROCESS_ID';   
	        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, null, null, null, null, null, null);
	        execute immediate sqlStatement;
	        commit;
        end if;
        g_sessionList.delete(p_processId);
    end;

	------------------------------------------------------------------------------------------------

    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure CLOSE_SESSION(p_processId number, p_stepsToDo number, p_stepsDone number, p_processInfo varchar2, p_status number)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
    begin
        if getSessionRecord(p_processId).process_id is null then
            return;
        end if;

		if getSessionRecord(p_processId).log_level > logLevelSilent then
	        sqlStatement := '
	        update PH_LILA_TABLE_NAME
	        set process_end = current_timestamp,
                last_update = current_timestamp';

            if p_stepsDone is not null then
                sqlStatement := sqlStatement || ', steps_done = PH_STEPS_DONE';
            end if;
            if p_stepsToDo is not null then
                sqlStatement := sqlStatement || ', steps_todo = PH_STEPS_TO_DO';
            end if;
            if p_processInfo is not null then
                sqlStatement := sqlStatement || ', info = ''PH_PROCESS_INFO''';
            end if;     
            if p_status is not null then
                sqlStatement := sqlStatement || ', status = PH_STATUS';
            end if;     
            
            sqlStatement := sqlStatement || ' where id = PH_PROCESS_ID'; 
	        sqlStatement := replacePlaceHolders(p_processId, sqlStatement, null, p_status, p_processInfo, null, p_stepsToDo, p_stepsDone, null);
	        execute immediate sqlStatement;
	        commit;
        end if;
        g_sessionList.delete(p_processId);
    end;

	------------------------------------------------------------------------------------------------

    function NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_tabNamePrefix VARCHAR2 DEFAULT 'LILA_PROCESS') return number
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(600);
        pProcessId number(19,0);
    begin
       -- If silent log mode don't do anything
        if p_logLevel > logLevelSilent then
	        -- Sicherstellen, dass die LOG-Tabellen existieren
	        createLogTables(p_tabNamePrefix);
        end if;

        select seq_lila_log.nextVal into pProcessId from dual;
        insertSession (p_tabNamePrefix, pProcessId, p_logLevel);

		if p_logLevel > logLevelSilent then
	        deleteOldLogs(pProcessId, upper(trim(p_processName)), p_daysToKeep);

	        sqlStatement := '
	        insert into PH_LILA_TABLE_NAME (
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
	        select
	            PH_PROCESS_ID, 
	            ''PH_PROCESS_NAME'', 
	            current_timestamp,
				current_timestamp,
                null,
	            PH_STEPS_TO_DO, 
	            null,
	            null,
	            ''START''
	        from dual';
	        sqlStatement := replacePlaceHolders(pProcessId, sqlStatement, p_processName, null, null, null, p_stepsToDo, null, null);
	        execute immediate sqlStatement;     

	        commit;
        end if;
        return pProcessId;
    end;

	------------------------------------------------------------------------------------------------

    -- Opens/starts a new logging session.
    -- The returned process id must be stored within the calling procedure because it is the reference
    -- which is recommended for all following actions (e.g. CLOSE_SESSION, DEBUG, SET_PROCESS_STATUS).
    function NEW_SESSION(p_processName varchar2, p_logLevel number, p_daysToKeep number, p_tabNamePrefix varchar2 default 'LILA_PROCESS') return number
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(600);
        pProcessId number(19,0);
    begin
        -- If silent log mode don't do anything
        if p_logLevel > logLevelSilent then
	        -- Sicherstellen, dass die LOG-Tabellen existieren
	        createLogTables(p_tabNamePrefix);
        end if;

        select seq_lila_log.nextVal into pProcessId from dual;
        insertSession (p_tabNamePrefix, pProcessId, p_logLevel);

		if p_logLevel > logLevelSilent then
	        deleteOldLogs(pProcessId, upper(trim(p_processName)), p_daysToKeep);

	        sqlStatement := '
	        insert into PH_LILA_TABLE_NAME (
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
	        select
	            PH_PROCESS_ID, 
	            ''PH_PROCESS_NAME'', 
	            current_timestamp,
	            current_timestamp,
	            null, 
	            null,
	            null, 
	            0,
	            ''START''
	        from dual';
	        sqlStatement := replacePlaceHolders(pProcessId, sqlStatement, p_processName, null, null, null, null, null, null);
	        execute immediate sqlStatement;     

	        commit;
        end if;
        return pProcessId;
    end;
    
	------------------------------------------------------------------------------------------------

    PROCEDURE IS_ALIVE
    as
        pProcessName number(19,0);
    begin
        pProcessName := new_session('LILA Life Check', logLevelDebug, null);
        debug(pProcessName, 'First Message of LILA');
        close_session(pProcessName, 1, 1, 'OK', 1);
    end;

END LILA;
