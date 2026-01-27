create or replace PACKAGE BODY LILA AS

    ---------------------------------------------------------------
    -- Configuration
    ---------------------------------------------------------------
    -- Daten werden initial in die Tabelle geschrieben
    -- Nur, wenn sich die Konfiguration eines Prozesses endet, werden sie neu gelesen
    -- Also kein Dirty Write etc.
    -- Daten werden initial in die Tabelle geschrieben
    -- Nur, wenn sich die Konfiguration eines Prozesses endet, werden sie neu gelesen
    -- Also kein Dirty Write etc.
    TYPE t_config_rec IS RECORD (
        -- settings dedicated to one log session
        -- means that this record and the session record always must be synchron
        process_id                      NUMBER,
        process_name                    VARCHAR2(100),
        process_start                   TIMESTAMP,
        is_active                       PLS_INTEGER := 0, -- is the related process still working?
        steps_todo                      PLS_INTEGER,
        steps_done                      PLS_INTEGER := 0,
        log_level                       PLS_INTEGER,
        
        -- global settings for all log sessions
        flush_millis_threshold          PLS_INTEGER,
        flush_log_threshold             PLS_INTEGER,
        flush_process_threshold         PLS_INTEGER,
        flush_monitor_threshold         PLS_INTEGER,
        monitor_alert_threshold_factor  PLS_INTEGER,
        max_entries_per_monitor_action  PLS_INTEGER
    );
        
    ---------------------------------------------------------------
    -- Sessions
    ---------------------------------------------------------------
    -- Record representing the internal session
    -- Per started process one session
    TYPE t_session_rec IS RECORD (
        process_id          NUMBER(19,0),
        serial_no           PLS_INTEGER := 0,
        log_level           PLS_INTEGER := 0,
        steps_todo          PLS_INTEGER := 0,
        steps_done          PLS_INTEGER := 0,
        monitoring          PLS_INTEGER := 0,
        last_monitor_flush  TIMESTAMP, -- Zeitpunkt des letzten Monitor-Flushes
        last_log_flush      TIMESTAMP, -- Zeitpunkt des letzten Log-Flushes
        monitor_dirty_count PLS_INTEGER := 0,  -- monitor entries per process counter
        log_dirty_count     PLS_INTEGER := 0,  -- Logs per process counter
        tabName_master      VARCHAR2(100)
    );

    -- Table for several processes
    TYPE t_session_tab IS TABLE OF t_session_rec;
    g_sessionList t_session_tab := null;
    
    -- Indexes for lists
    TYPE t_idx IS TABLE OF PLS_INTEGER INDEX BY BINARY_INTEGER;
    v_indexSession t_idx;        

    ---------------------------------------------------------------
    -- Processes
    ---------------------------------------------------------------
    TYPE t_process_cache_map IS TABLE OF t_process_rec INDEX BY PLS_INTEGER;
    g_process_cache t_process_cache_map;
    g_process_dirty_count PLS_INTEGER := 0; 
    g_last_process_flush  TIMESTAMP;

    ---------------------------------------------------------------
    -- Monitoring
    ---------------------------------------------------------------
    TYPE t_monitor_buffer_rec IS RECORD (
        process_id      NUMBER(19,0),
        action_name     VARCHAR2(25),
        avg_action_time NUMBER,        -- Umbenannt
        action_time     TIMESTAMP,     -- Startzeitpunkt der Aktion
        used_time       NUMBER,        -- Dauer der letzten Ausführung (in Sek.)
        steps_done     PLS_INTEGER := 0, -- Hilfsvariable für Durchschnittsberechnung
        is_flushed      PLS_INTEGER := 0
    );
   
    -- Eine Nested Table, die nur die Historie EINER Aktion hält
    TYPE t_action_history_tab IS TABLE OF t_monitor_buffer_rec;
    
    TYPE t_cache_num IS TABLE OF NUMBER INDEX BY VARCHAR2(100);
    TYPE t_cache_ts  IS TABLE OF TIMESTAMP INDEX BY VARCHAR2(100);
    TYPE t_cache_int IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(100);
    
    v_cache_avg   t_cache_num; -- Speichert den aktuellen avg_action_time
    v_cache_last  t_cache_ts;  -- Speichert den letzten action_time
    v_cache_count t_cache_int; -- Speichert die Anzahl (steps_done)
    
    -- Das Haupt-Objekt: Ein assoziatives Array, das für jede 
    -- Kombi (Key) eine eigene Historie-Tabelle speichert.
    TYPE t_monitor_map IS TABLE OF t_action_history_tab INDEX BY VARCHAR2(100);
    g_monitor_groups t_monitor_map;
                
    ---------------------------------------------------------------
    -- Logging
    ---------------------------------------------------------------
    TYPE t_log_buffer_rec IS RECORD (
        process_id      NUMBER(19,0),
        log_level       PLS_INTEGER,
        log_text        VARCHAR2(4000),
        log_time        TIMESTAMP,
        serial_no       PLS_INTEGER,
        err_stack       VARCHAR2(4000),
        err_backtrace   VARCHAR2(4000),
        err_callstack   VARCHAR2(4000)
    );
    
    -- Die Liste für den Bulk-Speicher
    -- Die flache Liste der Log-Einträge
    TYPE t_log_history_tab IS TABLE OF t_log_buffer_rec;
    
    -- Das Haupt-Objekt für Logs: 
    -- Key ist hier die process_id (als String gewandelt für die Map)
    TYPE t_log_map IS TABLE OF t_log_history_tab INDEX BY VARCHAR2(100);
    g_log_groups t_log_map;
    
    -- Steuerungsvariablen (Analog zum Monitoring)
--    g_log_dirty_count PLS_INTEGER := 0; 
    
    ---------------------------------------------------------------
    -- General Variables
    ---------------------------------------------------------------

    -- ALERT Registration
    g_isAlertRegistered BOOLEAN := false;
    g_alertCode_Flush CONSTANT varchar2(25) := 'LILA_ALERT_FLUSH_CFG';
    g_alertCode_Read  CONSTANT varchar2(25) := 'LILA_ALERT_READ_CFG';
    
    CONFIG_TABLE constant varchar2(20) := 'LILA_CONFIG';


    -- general Flush Time-Duration
    g_flush_millis_threshold PLS_INTEGER            := 1500; 
    g_flush_log_threshold PLS_INTEGER               := 100;
    g_flush_process_threshold PLS_INTEGER           := 100;
    g_max_entries_per_monitor_action PLS_INTEGER    := 1000; -- Round Robin: Max. Anzahl Einträge für eine Aktion je Action
    g_flush_monitor_threshold PLS_INTEGER           := 100; -- Max. Anzahl Monitoreinträge für das Flush
    g_monitor_alert_threshold_factor NUMBER         := 2.0; -- Max. Ausreißer in der Dauer eines Verarbeitungsschrittes
    
    -- Throttling for SIGNALs
    g_last_signal_time TIMESTAMP := SYSTIMESTAMP - INTERVAL '1' DAY;

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
    function getProcessRecord(p_processId number) return t_process_rec;
    procedure checkUpdateConfiguration;
    procedure refreshConfiguration(p_processId number);
    procedure refreshSession(p_configRec t_config_rec);
    
    
    --------------------------------------------------------------------------
    -- Copy actual process and session data to config record
    --------------------------------------------------------------------------
    function copyToConfig(p_processId number) return t_config_rec
    as
        l_sessionRec t_session_rec;
        l_processRec t_process_rec;
        l_configRec  t_config_rec;
    begin
        l_sessionRec := getSessionRecord(p_processId);
        l_processRec := getProcessRecord(p_processId);
        
        if l_sessionRec.process_id is null or l_processRec.id is null then return null; end if;

        l_configRec.process_id := l_sessionRec.process_id;
        l_configRec.process_name := l_processRec.process_name;
        l_configRec.process_start := l_processRec.process_start;
        l_configRec.is_active := 1;
        l_configRec.steps_todo := l_processRec.steps_todo;
        l_configRec.steps_done := l_processRec.steps_done;
        l_configRec.log_level := l_sessionRec.log_level;
        l_configRec.flush_log_threshold := g_flush_log_threshold;
        l_configRec.flush_millis_threshold := g_flush_millis_threshold;
        l_configRec.flush_process_threshold := g_flush_process_threshold;
        l_configRec.flush_monitor_threshold := g_flush_monitor_threshold;
        l_configRec.monitor_alert_threshold_factor := g_monitor_alert_threshold_factor;
        l_configRec.max_entries_per_monitor_action := g_max_entries_per_monitor_action;
        
        return l_configRec;

    end;

    --------------------------------------------------------------------------
    -- Millis between two timestamps
    --------------------------------------------------------------------------
    function get_ms_diff(p_start timestamp, p_end timestamp) return number is
        v_diff interval day(0) to second(3); -- Präzision auf ms begrenzen
    begin
        v_diff := p_end - p_start;
        -- Wir extrahieren nur die Sekunden inklusive der Nachkommastellen (ms)
        -- und addieren die Minuten/Stunden/Tage als Sekunden-Vielfache
        return (extract(day from v_diff) * 86400000)
             + (extract(hour from v_diff) * 3600000)
             + (extract(minute from v_diff) * 60000)
             + (extract(second from v_diff) * 1000);
    end;   

    /*
        Internal methods are written in lowercase and camelCase
    */
    
    -- register to Alerts
    procedure registerForAlert
    as
    begin
        if not g_isAlertRegistered then
            DBMS_ALERT.REGISTER(g_alertCode_Flush);
            DBMS_ALERT.REGISTER(g_alertCode_Read);
        end if;
    end;

	--------------------------------------------------------------------------    
    -- global exception handling
    function should_raise_error(p_processId number) return boolean
    as
    begin
        -- Die Logik ist hier zentral gekapselt
        if p_processId is not null and v_indexSession.EXISTS(p_processId) 
           and g_sessionList(v_indexSession(p_processId)).log_level >= logLevelDebug 
        then
            return true;
        end if;
        return false;
    exception
        when others then return false; -- Sicherheit geht vor
    end;  
    
	--------------------------------------------------------------------------

    -- run execute immediate with exception handling
    procedure run_sql(p_sqlStmt varchar2)
    as
    begin
        execute immediate p_sqlStmt;
        
    exception
        when OTHERS then
            DBMS_OUTPUT.PUT_LINE('DDL-Fehler bei: ' || p_sqlStmt);
            DBMS_OUTPUT.PUT_LINE(SQLERRM);
    end;
    
	--------------------------------------------------------------------------

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

	--------------------------------------------------------------------------

    function replaceNameDetailTable(p_sqlStatement varchar2, p_placeHolder varchar2, p_tableName varchar2) return varchar2
    as
    begin
        return replace(p_sqlStatement, p_placeHolder, p_tableName || SUFFIX_DETAIL_NAME);
    end;
    
	--------------------------------------------------------------------------

    function replaceNameMasterTable(p_sqlStatement varchar2, p_placeHolder varchar2, p_tableName varchar2) return varchar2
    as
    begin
        return replace(p_sqlStatement, p_placeHolder, p_tableName);
    end;
    
	--------------------------------------------------------------------------

    -- Creates LOG tables and the sequence for the process IDs if tables or sequence don't exist
    -- For naming rules of the tables see package description
    procedure createLogTables(p_TabNameMaster varchar2)
    as
        sqlStmt varchar2(1500);
    begin
        if not objectExists('SEQ_LILA_LOG', 'SEQUENCE') then
            sqlStmt := 'CREATE SEQUENCE SEQ_LILA_LOG MINVALUE 0 MAXVALUE 9999999999999999999999999999 INCREMENT BY 1 START WITH 1 CACHE 10 NOORDER  NOCYCLE  NOKEEP  NOSCALE  GLOBAL';
            execute immediate sqlStmt;
        end if;
        
        if not objectExists(CONFIG_TABLE, 'TABLE') then
            sqlStmt := '
            create table ' || CONFIG_TABLE || ' (
                process_id                     NUMBER(19,0),
                process_name                   VARCHAR2(100),
                process_start                  TIMESTAMP(6),
                steps_todo                     NUMBER,
                steps_done                     NUMBER,
                is_active                      NUMBER,
                log_level                      NUMBER,
                flush_millis_threshold         NUMBER,
                flush_log_threshold            NUMBER,
                flush_process_threshold        NUMBER,
                flush_monitor_threshold        NUMBER,
                monitor_alert_threshold_factor NUMBER,
                max_entries_per_monitor_action NUMBER
            )';
            run_sql(sqlStmt);            
        end if;

        if not objectExists(p_TabNameMaster, 'TABLE') then
            -- Master table
            sqlStmt := '
            create table PH_MASTER_TABLE ( 
                id number(19,0),
                process_name varchar2(100),
                log_level number,
                process_start timestamp(6),
                process_end timestamp(6),
                last_update timestamp(6),
                steps_todo number,
                steps_done number,
                status number(2,0),
                info clob,
                tabNameMaster varchar2(100)
            )';
            sqlStmt := replaceNameMasterTable(sqlStmt, PARAM_MASTER_TABLE, p_TabNameMaster);
            run_sql(sqlStmt);
        end if;

        if not objectExists(p_TabNameMaster || SUFFIX_DETAIL_NAME, 'TABLE') then
            -- Details table
            sqlStmt := '
            create table PH_DETAIL_TABLE (
                "PROCESS_ID"        number(19,0),
                "NO"                number(19,0),
                "INFO"              clob,
                "LOG_LEVEL"         varchar2(10),
                "SESSION_TIME"      timestamp  DEFAULT SYSTIMESTAMP,
                "SESSION_USER"      varchar2(50),
                "HOST_NAME"         varchar2(50),
                "ERR_STACK"         clob,
                "ERR_BACKTRACE"     clob,
                "ERR_CALLSTACK"     clob,
                "MONITORING"        NUMBER(1,0) DEFAULT 0,
                "MON_ACTION"        VARCHAR2(100),
                "MON_USED_MILLIS"   NUMBER(19,0), -- Millis als Zahl für einfache Auswertung
                "MON_AVG_MILLIS"    NUMBER(19,0),
                "MON_STEPS_DONE"    NUMBER(19,0)
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
            -- creating log files mustn't fail
            RAISE;
     end;
     
	--------------------------------------------------------------------------
    -- Kills log entries depending to their age in days and process name.
    -- Matching of process name is not case sensitive
	procedure deleteOldLogs(p_processId number, p_processName varchar2, p_daysToKeep number)
    as
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
        if sessionRec.process_id is null then
            return; 
        end if;
        
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
	        if t_rc%isopen then 
                close t_rc;
            end if;
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
            if should_raise_error(p_processId) then
                RAISE;
            end if;
	end;
    
	--------------------------------------------------------------------------

    procedure refreshConfiguration(p_processId number)
    as
        l_configRec t_config_rec;
        sqlStatement varchar2(600);
    begin
        sqlStatement := '
        select
            process_id,
            process_name,
            process_start,
            is_active,
            steps_todo,
            steps_done,
            log_level,
            flush_millis_threshold,
            flush_log_threshold,
            flush_process_threshold,
            flush_monitor_threshold,
            monitor_alert_threshold_factor,
            max_entries_per_monitor_action
        from ' || CONFIG_TABLE || ' 
        where process_id = :PH_PROCESS_ID
        ';
        
        execute immediate sqlStatement into l_configRec USING p_processId;
        
        if l_configRec.process_id is not null then
            refreshSession(l_configRec);
        end if;
                
    exception
        when NO_DATA_FOUND then
            null;
        
        when OTHERS then
            if should_raise_error(p_processId) then
                RAISE;
            end if;
    end;
    
	--------------------------------------------------------------------------
    
    function getProcessRecord(p_processId number) return t_process_rec
    as
    begin
        if g_process_cache(p_processId).id is not null then
            return g_process_cache(p_processId);
        else
            return null;
        end if;
    end;

	--------------------------------------------------------------------------

    function readProcessRecord(p_processId number) return t_process_rec
    as
        sessionRec t_session_rec;
        processRec t_process_rec;
        sqlStatement varchar2(600);
    begin
        sqlStatement := '
        select
            id,
            process_name,
            log_level,
            process_start,
            process_end,
            last_update,
            steps_todo,
            steps_done,
            status,
            info,
            tabNameMaster
        from PH_MASTER_TABLE
        where id = :PH_PROCESS_ID';
        
        sessionRec := getSessionRecord(p_processId);
        if sessionRec.process_id is not null then
            sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, sessionRec.tabName_master);
            execute immediate sqlStatement into processRec USING p_processId;
        end if;
        return processRec;
        
    exception
        when others then
            if should_raise_error(p_processId) then
                RAISE;
            else
                return null;
            end if;
    end;

    --------------------------------------------------------------------------
    -- Persist config data
    --------------------------------------------------------------------------

    procedure persist_config_record(p_configRec t_config_rec)
    as
        pragma autonomous_transaction;
    begin
    
        execute immediate 
            'insert into ' || CONFIG_TABLE || ' 
            (PROCESS_ID, PROCESS_NAME, PROCESS_START, IS_ACTIVE, STEPS_TODO, LOG_LEVEL, FLUSH_MILLIS_THRESHOLD, FLUSH_LOG_THRESHOLD, FLUSH_PROCESS_THRESHOLD, 
             FLUSH_MONITOR_THRESHOLD, MONITOR_ALERT_THRESHOLD_FACTOR, MAX_ENTRIES_PER_MONITOR_ACTION)
            values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, 12)'
        USING p_configRec.process_id, p_configRec.process_name, p_configRec.process_start, p_configRec.is_active, p_configRec.steps_todo, p_configRec.log_level, 
              p_configRec.flush_millis_threshold, p_configRec.flush_log_threshold, p_configRec.flush_process_threshold,
              p_configRec.flush_monitor_threshold, p_configRec.monitor_alert_threshold_factor, p_configRec.max_entries_per_monitor_action;
              
        commit;
        
    exception
        when others then
            rollback;
            if should_raise_error(p_configRec.process_id) then
                RAISE;
            end if;
    end;
    
    -------------------------------------------------------------------------
    
    procedure truncateConfigTable
    as
        pragma autonomous_transaction;
    begin
        execute immediate 'truncate table ' || CONFIG_TABLE;
        commit;
        
    exception
        when others then
            rollback;
--            if should_raise_error(p_configRec.process_id) then
--                RAISE;
--            end if;
    end;
    
    -------------------------------------------------------------------------
    
    procedure flushConfig
    as
        v_idx PLS_INTEGER;
        l_configRec t_config_rec;
    begin
        truncateConfigTable;
        for i in 1 .. g_sessionList.count loop
            l_configRec := copyToConfig(g_sessionList(i).process_id);
            persist_config_record(l_configRec);
        null;
        end loop;
    end;
    
    -------------------------------------------------------------------------
    procedure update_config_record(p_configRec t_config_rec)
    as
        pragma autonomous_transaction;
    begin
        if p_configRec.process_id is null then
            return;
        end if;
        
        execute immediate 
            'update ' || CONFIG_TABLE || ' 
            (IS_ACTIVE, STEPS_TODO, STEPS_DONE, LOG_LEVEL, FLUSH_MILLIS_THRESHOLD, FLUSH_LOG_THRESHOLD, FLUSH_PROCESS_THRESHOLD, FLUSH_MONITOR_THRESHOLD, MONITOR_ALERT_THRESHOLD_FACTOR, MAX_ENTRIES_PER_MONITOR_ACTION)
            values (:2, :3, :4, :5, :6, :7, :8, :9, :10, :11)
            where process_id = :1'
        USING p_configRec.process_id, p_configRec.is_active, p_configRec.steps_todo, p_configRec.steps_done, p_configRec.log_level, 
              p_configRec.flush_millis_threshold, p_configRec.flush_log_threshold, p_configRec.flush_process_threshold,
              p_configRec.flush_monitor_threshold, p_configRec.monitor_alert_threshold_factor, p_configRec.max_entries_per_monitor_action;
        
        commit;
        
    exception
        when others then
            rollback;
            if should_raise_error(p_configRec.process_id) then
                RAISE;
            end if;
    end;
    
    -------------------------------------------------------------------------
    procedure deactivate_config_data(p_processId number)
    as
        pragma autonomous_transaction;
    begin
        execute immediate 'update ' || CONFIG_TABLE || ' set IS_ACTIVE = 0 where process_id = :1'
        USING p_processId;
        commit;
        
    exception
        when others then
            rollback;
            if should_raise_error(p_processId) then
                RAISE;
            end if;
    end;

    --------------------------------------------------------------------------
    -- Flush monitor data to detail table
    --------------------------------------------------------------------------
    procedure persist_log_data(
        p_processId    number,
        p_target_table varchar2,
        p_seqs         sys.odcinumberlist,
        p_levels       sys.odcinumberlist,
        p_texts        sys.odcivarchar2list,
        p_times        sys.odcidatelist,
        p_stacks       sys.odcivarchar2list,
        p_backtraces   sys.odcivarchar2list,
        p_callstacks   sys.odcivarchar2list
    )    
    as
        pragma autonomous_transaction;
    begin
        -- Bulk-Insert über alle gesammelten Log-Einträge
        forall i in 1 .. p_levels.count
            execute immediate 
                'insert into ' || p_target_table || ' 
                (PROCESS_ID, LOG_LEVEL, INFO, SESSION_TIME, NO, ERR_STACK, ERR_BACKTRACE, ERR_CALLSTACK, SESSION_USER, HOST_NAME)
                values (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10)'
            USING p_processId, p_levels(i), p_texts(i), p_times(i), p_seqs(i), p_stacks(i), p_backtraces(i), p_callstacks(i),
            SYS_CONTEXT('USERENV','SESSION_USER'), SYS_CONTEXT('USERENV','HOST');
        commit;
        
    exception
        when others then
            rollback;
            if should_raise_error(p_processId) then
                raise;
            end if;

    end;
    
	--------------------------------------------------------------------------
    
    -- initilizes writing to table
    -- decouples internal memory from autonomous transaction
    procedure flushLogs(p_processId number)
    as
        v_key          constant varchar2(100) := to_char(p_processId);
        v_targetTable  varchar2(150);
        v_idx_session  pls_integer;
        
        -- Bulk-Listen für den Datentransfer (Schema-Level Typen)
        v_levels       sys.odcinumberlist   := sys.odcinumberlist();
        v_texts        sys.odcivarchar2list := sys.odcivarchar2list();
        v_times        sys.odcidatelist     := sys.odcidatelist();
        v_seqs         sys.odcinumberlist   := sys.odcinumberlist();
        v_stacks       sys.odcivarchar2list := sys.odcivarchar2list();
        v_backtraces   sys.odcivarchar2list := sys.odcivarchar2list();
        v_callstacks   sys.odcivarchar2list := sys.odcivarchar2list();
    begin
        -- 1. Prüfen, ob Daten für diesen Prozess im Cache sind
        if not g_log_groups.EXISTS(v_key) or g_log_groups(v_key).COUNT = 0 then
            return;
        end if;
    
        -- 2. Ziel-Tabelle aus der Session-Liste ermitteln
        v_idx_session := v_indexSession(p_processId);
        v_targetTable := g_sessionList(v_idx_session).tabName_master || '_DETAIL';
    
        -- 3. Daten aus der hierarchischen Map in flache Listen sammeln
        for i in 1 .. g_log_groups(v_key).COUNT loop
            v_levels.EXTEND;     v_levels(v_levels.LAST)     := g_log_groups(v_key)(i).log_level;
            v_texts.EXTEND;      v_texts(v_texts.LAST)       := substrb(g_log_groups(v_key)(i).log_text, 1, 4000);
            v_times.EXTEND;      v_times(v_times.LAST)       := cast(g_log_groups(v_key)(i).log_time as date);
            v_seqs.EXTEND;       v_seqs(v_seqs.LAST)         := g_log_groups(v_key)(i).serial_no;
            
            -- Error-Stacks (begrenzt auf 4000 Byte für sys.odcivarchar2list)
            v_stacks.EXTEND;     v_stacks(v_stacks.LAST)     := substrb(g_log_groups(v_key)(i).err_stack, 1, 4000);
            v_backtraces.EXTEND; v_backtraces(v_backtraces.LAST) := substrb(g_log_groups(v_key)(i).err_backtrace, 1, 4000);
            v_callstacks.EXTEND; v_callstacks(v_callstacks.LAST) := substrb(g_log_groups(v_key)(i).err_callstack, 1, 4000);
        end loop;

        -- 4. Übergabe an die autonome Bulk-Persistierung
        persist_log_data(
            p_processId    => p_processId,
            p_target_table => v_targetTable,
            p_levels       => v_levels,
            p_texts        => v_texts,
            p_times        => v_times,
            p_seqs         => v_seqs,
            p_stacks       => v_stacks,
            p_backtraces   => v_backtraces,
            p_callstacks   => v_callstacks
        );
    
        -- 5. Cache für diesen Prozess leeren
        g_log_groups(v_key).DELETE;
    
    exception
        when others then
            -- Zentrale Fehlerbehandlung nutzen
            if should_raise_error(p_processId) then
                raise;
            end if;
    end;
    
	--------------------------------------------------------------------------
    
    procedure write_to_log_buffer(
        p_processId number, 
        p_level number,
        p_text varchar2,
        p_errStack varchar2,
        p_errBacktrace varchar2,
        p_errCallstack varchar2
    ) 
    is
        v_idx PLS_INTEGER;
        v_key varchar2(100) := to_char(p_processId);
        v_new_log t_log_buffer_rec;
    begin
        v_idx := v_indexSession(p_processId);
        g_sessionList(v_idx).serial_no := nvl(g_sessionList(v_idx).serial_no, 0) + 1;

        v_new_log.serial_no := g_sessionList(v_idx).serial_no;
    
        -- 1. Gruppe initialisieren
        if not g_log_groups.EXISTS(v_key) then
            g_log_groups(v_key) := t_log_history_tab();
        end if;
    
        -- 2. Record befüllen
        v_new_log.process_id    := p_processId; -- Jetzt vorhanden
        v_new_log.log_level     := p_level;
        v_new_log.log_text      := p_text;
        v_new_log.log_time      := systimestamp;
        v_new_log.serial_no     := g_sessionList(v_indexSession(p_processId)).serial_no;
        v_new_log.err_stack     := p_errStack;
        v_new_log.err_backtrace := p_errBacktrace;
        v_new_log.err_callstack := p_errCallstack;
            
        -- 3. In den Cache hängen
        g_log_groups(v_key).EXTEND;
        g_log_groups(v_key)(g_log_groups(v_key).LAST) := v_new_log;
    
    end;


    /*
        Methods dedicated to the g_monitorList
    */
    
    --------------------------------------------------------------------------
    -- Write monitor data to detail table
    --------------------------------------------------------------------------
    procedure persist_monitor_data(
        p_processId    number,
        p_target_table varchar2,
        p_ids          sys.odcinumberlist,
        p_actions      sys.odcivarchar2list,
        p_steps_done   sys.odcinumberlist,
        p_used         sys.odcinumberlist,
        p_avgs         sys.odcinumberlist, -- NEU: Liste für avg_action_time
        p_times        sys.odcidatelist
    )
    as
        pragma autonomous_transaction;
    begin
        if p_ids.count > 0 then
                forall i in 1 .. p_ids.count
                    execute immediate 
                    'insert into ' || p_target_table || ' 
                    (PROCESS_ID, MON_ACTION, MON_STEPS_DONE, MON_USED_MILLIS, MON_AVG_MILLIS, SESSION_TIME, MONITORING, SESSION_USER, HOST_NAME)
                    values (:1, :2, :3, :4, :5, :6, 1, :7, :8)'
                using p_ids(i), p_actions(i), p_steps_done(i), p_used(i), p_avgs(i), p_times(i),
                    SYS_CONTEXT('USERENV','SESSION_USER'), SYS_CONTEXT('USERENV','HOST')
                
                ;
            commit;
        end if;
        
    exception
        when others then
            rollback;
            if should_raise_error(p_processId) then
                raise;
            end if;

    end;

    --------------------------------------------------------------------------
    -- Write monitor data to detail table
    --------------------------------------------------------------------------
    procedure flushMonitor(p_processId number)
    as
        v_sessionRec  t_session_rec;
        v_targetTable varchar2(150);
        v_key         varchar2(100);
        
        -- Sammlungen für den Datentransfer
        v_ids           sys.odcinumberlist   := sys.odcinumberlist();
        v_actions       sys.odcivarchar2list := sys.odcivarchar2list();
        v_steps_done    sys.odcinumberlist   := sys.odcinumberlist();
        v_used          sys.odcinumberlist   := sys.odcinumberlist();
        v_avgs          sys.odcinumberlist   := sys.odcinumberlist(); -- NEU
        v_times         sys.odcidatelist     := sys.odcidatelist();
    begin
        v_sessionRec := getSessionRecord(p_processId);
        if v_sessionRec.tabName_master is null then return; end if;
        v_targetTable := v_sessionRec.tabName_master || '_DETAIL';
    
        -- SCHRITT 1: Daten aus dem Speicher sammeln (unverändert)
        v_key := g_monitor_groups.FIRST;
        while v_key is not null loop
            if g_monitor_groups(v_key).COUNT > 0 
               and g_monitor_groups(v_key)(1).process_id = p_processId then
                for i in 1 .. g_monitor_groups(v_key).COUNT loop
                    if g_monitor_groups(v_key)(i).is_flushed = 0 then
                        v_ids.extend;           v_ids(v_ids.last) := g_monitor_groups(v_key)(i).process_id;
                        v_actions.extend;       v_actions(v_actions.last) := g_monitor_groups(v_key)(i).action_name;
                        v_steps_done.extend;    v_steps_done(v_steps_done.last) := g_monitor_groups(v_key)(i).steps_done;
                        v_used.extend;          v_used(v_used.last) := g_monitor_groups(v_key)(i).used_time;
                        v_avgs.extend;          v_avgs(v_avgs.last) := g_monitor_groups(v_key)(i).avg_action_time;
                        v_times.extend;         v_times(v_times.last) := cast(g_monitor_groups(v_key)(i).action_time as date);
                    end if;
                end loop;
            end if;
            v_key := g_monitor_groups.NEXT(v_key);
        end loop;
    
        -- SCHRITT 2: Autonome Persistierung aufrufen
        if v_ids.COUNT > 0 then
            persist_monitor_data(
                p_processId    => p_processId,
                p_target_table => v_targetTable,
                p_ids          => v_ids,
                p_actions      => v_actions,
                p_steps_done   => v_steps_done,
                p_used         => v_used,
                p_avgs         => v_avgs, -- NEU übergeben
                p_times        => v_times
            );
    
            -- SCHRITT 3: Im Speicher als geflusht markieren (unverändert)
            v_key := g_monitor_groups.FIRST;
            while v_key is not null loop
                if g_monitor_groups(v_key).COUNT > 0 
                   and g_monitor_groups(v_key)(1).process_id = p_processId then
                    for i in 1 .. g_monitor_groups(v_key).COUNT loop
                        g_monitor_groups(v_key)(i).is_flushed := 1;
                    end loop;
                end if;
                v_key := g_monitor_groups.NEXT(v_key);
            end loop;
        end if;
        
    exception
        when others then
            rollback;
            if should_raise_error(p_processId) then
                RAISE;
            end if;
    end;    
    
	--------------------------------------------------------------------------

    procedure sync_monitor(p_processId number, p_force boolean default false)
    as
        v_idx PLS_INTEGER;
        v_ms_since_flush NUMBER;
        v_now constant timestamp := systimestamp;

    begin
        -- 1. Index der Session holen
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if;
        v_idx := v_indexSession(p_processId);
    
        -- 2. Dirty-Zähler für diesen spezifischen Prozess erhöhen
        g_sessionList(v_idx).monitor_dirty_count := g_sessionList(v_idx).monitor_dirty_count + 1;
    
        -- 3. Zeitdifferenz seit letztem Flush berechnen
        -- Falls noch nie geflusht wurde (Start), setzen wir die Differenz hoch
        if g_sessionList(v_idx).last_monitor_flush is null then
            v_ms_since_flush := g_flush_millis_threshold + 1;
        else
            v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_monitor_flush, v_now);
        end if;
    
        -- 4. Die "Smarte" Flush-Bedingung: Menge ODER Zeit ODER Force
        if p_force 
           or g_sessionList(v_idx).monitor_dirty_count >= g_flush_monitor_threshold 
           or v_ms_since_flush >= g_flush_millis_threshold
        then
            flushMonitor(p_processId);
            
            -- Reset der prozessspezifischen Steuerungsdaten
            g_sessionList(v_idx).monitor_dirty_count := 0;
            g_sessionList(v_idx).last_monitor_flush  := v_now;
        end if;
    end;
    
    --------------------------------------------------------------------------
    -- Hilfsfunktion (intern): Erzeugt den einheitlichen Key für den Index
    --------------------------------------------------------------------------
    function buildMonitorKey(p_processId number, p_actionName varchar2) return varchar2
    is
    begin
        -- Ein Key repräsentiert eine Gruppe von Einträgen (die Historie dieser Aktion)
        return to_char(p_processId) || '_' || p_actionName;
    end;

    --------------------------------------------------------------------------
    -- Calculation average time used
    --------------------------------------------------------------------------
    function calculate_avg(
        p_old_avg    number,
        p_curr_count pls_integer,
        p_new_value  number
    ) return number 
    is
        v_meas_count pls_integer;
    begin
        -- Die Anzahl der Intervalle ist die Anzahl der bisherigen Punkte
        v_meas_count := p_curr_count;
    
        -- Erster Messwert: Der Durchschnitt ist der Wert selbst
        if v_meas_count = 1 then
            return p_new_value;
        end if;
    
        -- Gleitender Durchschnitt über n Intervalle
        -- Formel: ((Schnitt_alt * (n-1)) + Wert_neu) / n
        return ((p_old_avg * (v_meas_count - 1)) + p_new_value) / v_meas_count;
    end;
    
    --------------------------------------------------------------------------
    -- Helper for raising alerts
    --------------------------------------------------------------------------
    procedure raise_alert(
        p_processId number, 
        p_action varchar2,
        p_step PLS_INTEGER,
        p_used_time number,
        p_expected number
    )
    as
        l_msg VARCHAR2(4000);
    begin
        l_msg := 'PERFORMANCE ALERT: ' || p_action || ' - Step: ' || p_step || 
                 ' used ' || p_used_time || 'ms (expected: ' || p_expected || 'ms)';
                 
        -- Log to Buffer
        write_to_log_buffer(
            p_processId, 
            logLevelMonitor,
            l_msg,
            null,
            null,
            null
        );

    end;
    
    --------------------------------------------------------------------------
    -- Check if a single step needs more time than average over all steps per action
    --------------------------------------------------------------------------
    procedure validateDurationInAverage(p_processId number, p_monitor_rec t_monitor_buffer_rec)
    as
        l_threshold_duration NUMBER;
    begin
        IF p_monitor_rec.steps_done > 5 THEN 
            
            l_threshold_duration := p_monitor_rec.avg_action_time * g_monitor_alert_threshold_factor;
        
            IF p_monitor_rec.used_time > l_threshold_duration THEN
                -- Hier wird die Alert-Aktion ausgelöst
                raise_alert(
                    p_processId => p_processId,
                    p_action    => p_monitor_rec.action_name,
                    p_step      => p_monitor_rec.steps_done,
                    p_used_time => p_monitor_rec.used_time,
                    p_expected  => p_monitor_rec.avg_action_time
                );
            END IF;
        END IF;

    end;
    
    --------------------------------------------------------------------------
    -- Creating and adding/updating a record in the monitor list
    --------------------------------------------------------------------------
    procedure insertMonitor (p_processId number, p_actionName varchar2)
    as
        v_key        constant varchar2(100) := buildMonitorKey(p_processId, p_actionName);
        v_now        constant timestamp := systimestamp;
        v_used_time  number := 0;
        v_new_avg    number := 0;
        v_new_count  pls_integer := 1;
        v_history    t_action_history_tab;
        v_new_rec    t_monitor_buffer_rec;
    begin
        -- if monitoring is not activated do nothing here
        if v_indexSession.EXISTS(p_processId) and logLevelMonitor > g_sessionList(v_indexSession(p_processId)).log_level then
            return;
        end if;
    
        if v_cache_last.EXISTS(v_key) then
            v_used_time := get_ms_diff(v_cache_last(v_key), v_now); 
            
            -- Berechnung delegieren: 
            -- Wir übergeben den alten Schnitt und die aktuelle Punktanzahl (v_cache_count)
            v_new_avg   := calculate_avg(
                               p_old_avg    => v_cache_avg(v_key),
                               p_curr_count => v_cache_count(v_key),
                               p_new_value  => v_used_time
                           );
                           
            v_new_count := v_cache_count(v_key) + 1;
        else
            v_used_time := null;
            v_new_avg   := 0;
            v_new_count := 1;
        end if;
    
        -- 2. Caches sofort aktualisieren (für den nächsten Aufruf)
        v_cache_last(v_key)  := v_now;
        v_cache_avg(v_key)   := v_new_avg;
        v_cache_count(v_key) := v_new_count;
    
        -- 3. Historie-Management (nur wenn Logging aktiv ist)
        if not g_monitor_groups.EXISTS(v_key) then
            g_monitor_groups(v_key) := t_action_history_tab();
        end if;
    
        -- Wir arbeiten direkt mit der Referenz in der Map (ab Oracle 12c+ effizient)
        if g_monitor_groups(v_key).COUNT >= g_max_entries_per_monitor_action then
            g_monitor_groups(v_key).DELETE(g_monitor_groups(v_key).FIRST);
        end if;
    
        -- Neuen Record füllen
        v_new_rec.process_id      := p_processId;
        v_new_rec.action_name     := p_actionName;
        v_new_rec.action_time     := v_now;
        v_new_rec.used_time       := v_used_time;
        v_new_rec.avg_action_time := v_new_avg;
        v_new_rec.steps_done      := v_new_count;
    
        g_monitor_groups(v_key).EXTEND;
        g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST) := v_new_rec;
        
        validateDurationInAverage(p_processId, v_new_rec);
        sync_monitor(p_processId);
        
    exception
        when others then
            if should_raise_error(p_processId) then
                RAISE;
            end if;
    end;

    --------------------------------------------------------------------------
    -- Removing a record from monitor list
    --------------------------------------------------------------------------
    procedure removeMonitor(p_processId number, p_actionName varchar2)
    as
        v_key constant varchar2(100) := buildMonitorKey(p_processId, p_actionName);
    begin
        -- 1. Historie löschen
        if g_monitor_groups.EXISTS(v_key) then
            g_monitor_groups.DELETE(v_key);
        end if;
        
        -- 2. ALLE Caches löschen (Neu!)
        v_cache_avg.DELETE(v_key);
        v_cache_last.DELETE(v_key);
        v_cache_count.DELETE(v_key);
    end;

    --------------------------------------------------------------------------
    -- Removing a record from monitor list
    --------------------------------------------------------------------------
    function getLastMonitorEntry(p_processId number, p_actionName varchar2) return t_monitor_buffer_rec
    as
        v_key    constant varchar2(100) := buildMonitorKey(p_processId, p_actionName);
        v_empty  t_monitor_buffer_rec; -- Initial leerer Record als Fallback
    begin
        -- 1. Prüfen, ob die Gruppe (Action) im Cache existiert
        if g_monitor_groups.EXISTS(v_key) then
            -- 2. Prüfen, ob die Historie-Liste Einträge hat
            if g_monitor_groups(v_key).COUNT > 0 then
                -- Den letzten Eintrag (LAST) der verschachtelten Liste zurückgeben
                return g_monitor_groups(v_key)(g_monitor_groups(v_key).LAST);
            end if;
        end if;
    
        -- Falls nichts gefunden wurde, wird ein leerer Record zurückgegeben
        return v_empty;
    
    exception
        when others then
            -- Hier nutzen wir deine neue zentrale Fehler-Logik
            if should_raise_error(p_processId) then
                raise;
            end if;
            return v_empty;
    end;

    ----------------------------------------------------------------------
    
    function hasMonitorEntry(p_processId number, p_actionName varchar2) return boolean
    is
        v_key constant varchar2(100) := buildMonitorKey(p_processId, p_actionName);
    begin
        if not g_monitor_groups.EXISTS(v_key) then
            return false;
        end if;
        return (g_monitor_groups(v_key).COUNT > 0);
    
    exception
        when others then
            if should_raise_error(p_processId) then
                raise;
            end if;
            return false;
    end;
    
    --------------------------------------------------------------------------
    -- Monitoring a step
    --------------------------------------------------------------------------
    PROCEDURE MARK_STEP(p_processId NUMBER, p_actionName VARCHAR2)
    as
    begin
        insertMonitor (p_processId, p_actionName);     
    end;

    --------------------------------------------------------------------------

    FUNCTION GET_METRIC_AVG_DURATION(p_processId NUMBER, p_actionName VARCHAR2) return NUMBER
    as
        v_rec t_monitor_buffer_rec;
    begin
        v_rec := getLastMonitorEntry(p_processId, p_actionName);
        RETURN nvl(v_rec.avg_action_time, 0);
    end;
    
    --------------------------------------------------------------------------

    FUNCTION GET_METRIC_STEPS(p_processId NUMBER, p_actionName VARCHAR2) return NUMBER
    as
        v_rec t_monitor_buffer_rec;
    begin
        v_rec := getLastMonitorEntry(p_processId, p_actionName);
        RETURN nvl(v_rec.steps_done, 0);
    end;
    
    --------------------------------------------------------------------------
    /*
        Methods dedicated to config
    */
    
    --------------------------------------------------------------------------
        
    
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
        else
            listIndex := v_indexSession(p_processId);
            return g_sessionList(listIndex);
        end if;

    end;

	--------------------------------------------------------------------------

    -- Set values of a stored record in the internal process list by a given record
    procedure updateSessionRecord(p_sessionRecord t_session_rec)
    as
        listIndex number;
    begin
        listIndex := v_indexSession(p_sessionRecord.process_id);
        g_sessionList(listIndex) := p_sessionRecord;
    end;

	--------------------------------------------------------------------------

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

	--------------------------------------------------------------------------

    -- Creating and adding a new record to the process list
    -- and persist to config table
    procedure insertSession (p_tabName varchar2, p_processId number, p_logLevel PLS_INTEGER)
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

        g_sessionList(v_new_idx).process_id         := p_processId;
--        g_sessionList(v_new_idx).serial_no          := 0;
--        g_sessionList(v_new_idx).steps_todo         := p_stepsToDo;
        g_sessionList(v_new_idx).log_level          := p_logLevel;
        g_sessionList(v_new_idx).tabName_master     := p_tabName;
            -- Timestamp for flushing   
        g_sessionList(v_new_idx).last_monitor_flush := systimestamp;
        g_sessionList(v_new_idx).last_log_flush     := systimestamp;

        v_indexSession(p_processId) := v_new_idx;
        
    end;

	--------------------------------------------------------------------------

    -- Updates the status of a log entry in the main log table.
    procedure persist_process_record(p_process_rec t_process_rec)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
    begin
        sqlStatement := '
        update PH_MASTER_TABLE
        set status = :PH_STATUS,
            last_update = current_timestamp,
            process_end = :PH_PROCESS_END,
            steps_todo  = :PH_STEPS_TODO,
            steps_done  = :PH_STEPS_DONE,
            info        = :PH_INFO
        where id = :PH_PROCESS_ID';  

        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, p_process_rec.tabNameMaster);        
        execute immediate sqlStatement
        USING   p_process_rec.status, 
                p_process_rec.process_end,
                p_process_rec.steps_todo,
                p_process_rec.steps_done,
                p_process_rec.info,
                p_process_rec.id;
        
        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
            if should_raise_error(p_process_rec.id) then
                RAISE;
            end if;
    end;
 
    -------------------------------------------------------------------
    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure persist_close_session(p_processId number, p_tableName varchar2, p_stepsToDo number, p_stepsDone number, p_processInfo varchar2, p_status PLS_INTEGER)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(500);
        sqlCursor number := null;
        updateCount number;
    begin
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
        sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, p_tableName);
        
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

        commit;
                
    EXCEPTION
        WHEN OTHERS THEN
            IF DBMS_SQL.IS_OPEN(sqlCursor) THEN
                DBMS_SQL.CLOSE_CURSOR(sqlCursor);
            END IF;
            sqlCursor := null;
			rollback;
            if should_raise_error(p_processId) then
                RAISE;
            end if;
    end;

	--------------------------------------------------------------------------

    procedure persist_new_session(p_processId NUMBER, p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_tabNameMaster varchar2)
    as
        pragma autonomous_transaction;
        sqlStatement varchar2(600);
    begin
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
                log_level,
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
                :PH_LOG_LEVEL,
	            ''START''
            )';
            sqlStatement := replaceNameMasterTable(sqlStatement, PARAM_MASTER_TABLE, p_TabNameMaster);
	        execute immediate sqlStatement using p_processId, p_processName, p_stepsToDo, p_logLevel;     
	        commit;

	exception
	    when others then
	        rollback; -- Auch im Fehlerfall die Transaktion beenden
            if should_raise_error(p_processId) then
                RAISE;
            end if;
    end;

	--------------------------------------------------------------------------
    
    procedure sync_process(p_processId number, p_force boolean default false)
    as
        v_now constant timestamp := systimestamp;
        v_ms_since_flush number;
    begin
        -- no processes started
        if not g_process_cache.EXISTS(p_processId) then
            return;
        end if;

        -- increment dirty counter
        g_process_dirty_count := g_process_dirty_count + 1;        
        
        -- calculate time difference since last flush
        -- Falls noch nie geflusht wurde (Start), setzen wir die Differenz hoch
        if g_last_process_flush is null then
            v_ms_since_flush := g_flush_millis_threshold + 1;
        else
            v_ms_since_flush := get_ms_diff(g_last_process_flush, v_now);
        end if;
    
        -- 4. Die "Smarte" Flush-Bedingung: Menge ODER Zeit ODER Force
        if p_force 
           or g_process_dirty_count >= g_flush_process_threshold
           or v_ms_since_flush >= g_flush_millis_threshold
        then
            persist_process_record(g_process_cache(p_processId));            
            -- Reset der prozessspezifischen Steuerungsdaten
            g_process_dirty_count := 0;
            g_last_process_flush := v_now;
            
            -- look if another process changed configuration or asks for update
            checkUpdateConfiguration;   

        end if;
    end;
    
	--------------------------------------------------------------------------

    /*
		Public functions and procedures
    */

    procedure sync_log(p_processId number, p_force boolean default false)
    is
        v_idx            pls_integer;
        v_now            constant timestamp := systimestamp;
        v_ms_since_flush number;
    begin
        -- 1. Index der Session holen
        v_idx := v_indexSession(p_processId);
    
        -- 2. In-Memory Zähler für Logs dieses Prozesses erhöhen
        g_sessionList(v_idx).log_dirty_count := g_sessionList(v_idx).log_dirty_count + 1;
    
        -- 3. Zeit seit dem letzten Log-Flush berechnen
        -- (get_ms_diff ist Ihre optimierte Funktion)
        if g_sessionList(v_idx).last_log_flush is null then
            v_ms_since_flush := g_flush_millis_threshold + 1;
        else
            v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_log_flush, v_now);
        end if;
    
        -- 4. Flush-Bedingung: Menge ODER Zeit ODER Force
        if p_force 
           or g_sessionList(v_idx).log_dirty_count >= g_flush_log_threshold 
           or v_ms_since_flush >= g_flush_millis_threshold
        then
            -- Alle gepufferten Logs dieses Prozesses in die DB schreiben
            flushLogs(p_processId);
--            g_log_dirty_count := 0;
            
            -- Steuerungsdaten für diesen Prozess zurücksetzen
            g_sessionList(v_idx).log_dirty_count := 0;
            g_sessionList(v_idx).last_log_flush  := v_now;
        end if;
                
    exception
        when others then
            -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
            if should_raise_error(p_processId) then
                raise;
            end if;
    end;

	--------------------------------------------------------------------------

    procedure refreshSession(p_configRec t_config_rec)
    as
        p_sessionRec t_session_rec;
    begin
        -- at first clean dirty memory and write to table
        sync_log(p_configRec.process_id, true);
        sync_process(p_configRec.process_id, true);
        sync_monitor(p_configRec.process_id, true);
                
        p_sessionRec := getSessionRecord(p_configRec.process_id); -- get session record from memory
        if p_sessionRec.process_id = p_configRec.process_id then
            -- set actual values to session and refresh session record in memory
            p_sessionRec.log_level := p_configRec.log_level;
            p_sessionRec.steps_todo := p_configRec.steps_todo;
            p_sessionRec.steps_done := p_configRec.steps_todo;
            updateSessionRecord(p_sessionRec);    
        end if;
        
        -- set global parameters
        g_flush_millis_threshold := p_configRec.flush_millis_threshold;
        g_flush_log_threshold := p_configRec.flush_log_threshold;
        g_flush_process_threshold := p_configRec.flush_process_threshold;
        g_flush_monitor_threshold := p_configRec.flush_monitor_threshold;
        g_monitor_alert_threshold_factor := p_configRec.monitor_alert_threshold_factor;
        g_max_entries_per_monitor_action := p_configRec.max_entries_per_monitor_action;       

dbms_output.put_line('okay');

    exception
        when others then
            -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
            if should_raise_error(p_configRec.process_id) then
                raise;
            end if;
    end;
    
	--------------------------------------------------------------------------

    
--    procedure loadConfiguration
	--------------------------------------------------------------------------

    procedure checkUpdateConfiguration
    as
        l_msg VARCHAR2(1800);
        l_status INTEGER;
        l_processId number;
        
        l_key  VARCHAR2(20)  := 'P_ID=';
        l_start PLS_INTEGER;
        l_end   PLS_INTEGER;
        l_configRec t_config_rec;
    begin
        -- signal for write dirty configuration records
        DBMS_ALERT.WAITONE(g_alertCode_Flush, l_msg, l_status, 0);
        if l_status = 0 then
            flushConfig;
        end if;

        -- timeout => 0 bedeutet: Nicht warten, nur kurz gucken
        DBMS_ALERT.WAITONE(g_alertCode_Read, l_msg, l_status, 0);
        if l_status = 0 then
            l_start := INSTR(l_msg, l_key);
            -- zerlege l_msg
            -- <Bla='Blubb><P_ID=3400><Aha=1>
            IF l_start > 0 THEN
                l_start := l_start + LENGTH(l_key); -- Gehe zum Anfang des Wertes
                l_end   := INSTR(l_msg, '>', l_start); -- Suche das schließende Tag
                l_processId   := to_number(SUBSTR(l_msg, l_start, l_end - l_start));
                refreshConfiguration(l_processId);
            end if;
        END IF;

      
    exception
        when others then
            null;
--            if should_raise_error(p_processId) then
--                RAISE;
--            end if;
    end;

    -- capsulation writing to log-buffer and synchronization of buffer
    procedure log_any(
        p_processId number, 
        p_level number,
        p_logText varchar2,
        p_errStack varchar2,
        p_errBacktrace varchar2,
        p_errCallstack varchar2
    )
    as
    begin    
        if v_indexSession.EXISTS(p_processId) and p_level <= g_sessionList(v_indexSession(p_processId)).log_level then
        write_to_log_buffer(
            p_processId, 
            p_level,
            p_logText,
            null,
            null,
            DBMS_UTILITY.FORMAT_CALL_STACK
        );
        end if;
        
        if p_level = logLevelError then
            -- in case of an error, performace is not the
            -- first problem of the parent process 
            sync_process(p_processId, true);
            sync_log(p_processId, true);
            sync_monitor(p_processId, true);        
        else
            sync_log(p_processId);
            sync_process(p_processId); -- master also because of the last_update timestamp
        end if;
        
    exception
        when others then
            -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
            if should_raise_error(p_processId) then
                raise;
            end if;
    end;
    
	--------------------------------------------------------------------------

    /*
		Public functions and procedures
    */

    -- Used by external Procedure to write a new log entry with log level DEBUG
    -- Details are adjusted to the debug level
    procedure DEBUG(p_processId number, p_logText varchar2)
    as
    begin
        log_any(
                p_processId, 
                logLevelDebug,
                p_logText,
                null,
                null,
                DBMS_UTILITY.FORMAT_CALL_STACK
            );
    end;

	--------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level INFO
    -- Details are adjusted to the info level
    procedure INFO(p_processId number, p_logText varchar2)
    as
    begin
        log_any(
            p_processId, 
            logLevelInfo,
            p_logText,
            null,
            null,
            null
        );
    end;

	--------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level ERROR
    -- Details are adjusted to the error level
    procedure ERROR(p_processId number, p_logText varchar2)
    as
    begin
        log_any(
            p_processId, 
            logLevelDebug,
            p_logText,
            DBMS_UTILITY.FORMAT_ERROR_STACK,
            DBMS_UTILITY.FORMAT_ERROR_BACKTRACE,
            DBMS_UTILITY.FORMAT_CALL_STACK
        );
    end;

	--------------------------------------------------------------------------

    -- Used by external Procedure to write a new log entry with log level WARN
    -- Details are adjusted to the warn level
    procedure WARN(p_processId number, p_logText varchar2)
    as
    begin
        log_any(
            p_processId, 
            logLevelInfo,
            p_logText,
            null,
            null,
            null
        );
    end;
     
	--------------------------------------------------------------------------
    
    procedure setAnyStatus(p_processId number, p_status PLS_INTEGER, p_processInfo varchar2, p_stepsToDo number, p_stepsDone number)
    as
    begin
       if v_indexSession.EXISTS(p_processId) then
            if p_status      is not null then g_process_cache(p_processId).status := p_status;        end if;
            if p_processInfo is not null then g_process_cache(p_processId).info := p_processInfo;     end if;
            if p_stepsToDo   is not null then g_process_cache(p_processId).steps_toDo := p_stepsToDo; end if;
            if p_stepsDone   is not null then g_process_cache(p_processId).steps_done := p_stepsDone; end if;
            
            sync_process(p_processId);
        end if;
        
    exception
        when others then
            -- Sicherheit für das Framework: Fehler im Flush dürfen Applikation nicht stoppen
            if should_raise_error(p_processId) then
                raise;
            end if;
    end;

    procedure SET_PROCESS_STATUS(p_processId number, p_status PLS_INTEGER, p_processInfo varchar2)
    as
    begin
        setAnyStatus(p_processId, p_status, p_processInfo, null, null);
    end;

	--------------------------------------------------------------------------

    procedure SET_PROCESS_STATUS(p_processId number, p_status PLS_INTEGER)
    as
    begin
        setAnyStatus(p_processId, p_status, null, null, null);
    end;

	--------------------------------------------------------------------------
    
     procedure SET_STEPS_TODO(p_processId number, p_stepsToDo number)
     as
     begin
        setAnyStatus(p_processId, null, null, p_stepsToDo, null);
     end;
   
	--------------------------------------------------------------------------
 
    procedure SET_STEPS_DONE(p_processId number, p_stepsDone number)
    as
    begin
        if v_indexSession.EXISTS(p_processId) then
--            g_sessionList(v_idx).steps_done := p_stepsDone;
            g_process_cache(p_processId).steps_done := p_stepsDone;
            sync_process(p_processId);
       end if;

    end;
    
	--------------------------------------------------------------------------
    
    procedure STEP_DONE(p_processId number)
    as
        sqlStatement varchar2(500);
        lStepCounter number;
    begin
        if v_indexSession.EXISTS(p_processId) then
--            g_sessionList(v_idx).steps_done := g_sessionList(v_idx).steps_done + 1;   
            g_process_cache(p_processId).steps_done := g_process_cache(p_processId).steps_done + 1;

            sync_process(p_processId);
        end if;
    end;
    
	--------------------------------------------------------------------------
    
    FUNCTION GET_PROCESS_DATA(p_processId NUMBER) return t_process_rec
    as
    begin
        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId);
        else return null;
        end if;
    end;

    FUNCTION GET_STEPS_DONE(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId).steps_done;
        else return 0;
        end if;
    end;

	--------------------------------------------------------------------------

    FUNCTION GET_STEPS_TODO(p_processId NUMBER) return PLS_INTEGER
    as
    begin
        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId).steps_todo;
        else return 0;
        end if;
    end;

	--------------------------------------------------------------------------
    
    function GET_PROCESS_START(p_processId NUMBER) return timestamp
    as
    begin
        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId).process_start;
        else return null;
        end if;
    end;
    
	--------------------------------------------------------------------------
    
    function GET_PROCESS_END(p_processId NUMBER) return timestamp
    as
    begin
        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId).process_end;
        else return null;
        end if;
    end;

	--------------------------------------------------------------------------

    function GET_PROCESS_STATUS(p_processId number) return PLS_INTEGER
    as 
    begin
        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId).status;
        else return 0;
        end if;
    end;

	--------------------------------------------------------------------------

    function GET_PROCESS_INFO(p_processId number) return varchar2
    as 
    begin
        if v_indexSession.EXISTS(p_processId) then
            return g_process_cache(p_processId).info;
        else return null;
        end if;
    end;

	--------------------------------------------------------------------------
    
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
    
	--------------------------------------------------------------------------

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

	--------------------------------------------------------------------------
    
    -- Ends an earlier started logging session by the process ID.
    -- Important! Ignores if the process doesn't exist! No exception is thrown!
    procedure CLOSE_SESSION(p_processId number)
    as
    begin
        close_session(
            p_processId   => p_processId, 
            p_stepsToDo   => null, 
            p_stepsDone   => null, 
            p_processInfo => null, 
            p_status      => null
        );
    end;

	--------------------------------------------------------------------------

    procedure CLOSE_SESSION(p_processId number, p_stepsToDo number, p_stepsDone number, p_processInfo varchar2, p_status PLS_INTEGER)
    as
        v_idx PLS_INTEGER;
    begin
        if v_indexSession.EXISTS(p_processId) then
            sync_process(p_processId, true);
            sync_log(p_processId, true);
            sync_monitor(p_processId, true);

--            if  logLevelSilent <= g_sessionList(v_indexSession(p_processId)).log_level then
                v_idx := v_indexSession(p_processId);
                g_sessionList(v_idx).steps_done := p_stepsDone;        
                persist_close_session(p_processId,  g_sessionList(v_idx).tabName_master, p_stepsToDo, p_stepsDone, p_processInfo, p_status);
                deactivate_config_data(p_processId);
                
                -- Eintrag aus internem Speicher entfernen
                g_sessionList.delete(v_indexSession(p_processId));
                v_indexSession.delete(p_processId); -- Auch den Index-Eintrag entfernen!
--            end if;
        end if;
    end;

	--------------------------------------------------------------------------
    
    FUNCTION NEW_SESSION(p_session_init t_session_init) RETURN NUMBER
    as
        pProcessId number(19,0);   
        v_new_rec t_process_rec;
    begin

       -- If silent log mode don't do anything
        if p_session_init.logLevel > logLevelSilent then
	        -- Sicherstellen, dass die LOG-Tabellen existieren
	        createLogTables(p_session_init.tabNameMaster);
        end if;

        select seq_lila_log.nextVal into pProcessId from dual;
        -- persist to session internal table
        insertSession (p_session_init.tabNameMaster, pProcessId, p_session_init.logLevel);

		if p_session_init.logLevel > logLevelSilent and p_session_init.daysToKeep is not null then
--	        deleteOldLogs(pProcessId, upper(trim(p_session_init.processName)), p_session_init.daysToKeep);
            persist_new_session(pProcessId, p_session_init.processName, p_session_init.logLevel, 
                p_session_init.stepsToDo, p_session_init.daysToKeep, p_session_init.tabNameMaster);
        end if;

        -- copy new details data to memory
        v_new_rec.id              := pProcessId;
        v_new_rec.tabNameMaster   := p_session_init.tabNameMaster;
        v_new_rec.process_name    := p_session_init.processName;
        v_new_rec.process_start   := current_timestamp;
        v_new_rec.process_end     := null;
        v_new_rec.last_update     := null;
        v_new_rec.steps_todo      := p_session_init.stepsToDo;
        v_new_rec.steps_done      := 0;
        v_new_rec.status          := 0;
        v_new_rec.info            := 'START';
        
        g_process_cache(pProcessId) := v_new_rec;
        registerForAlert;
        return pProcessId;

    end;

    
    FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_tabNameMaster varchar2 default 'LILA_LOG') return number
    as
        p_session_init t_session_init;
    begin
    
        p_session_init.processName := p_processName;
        p_session_init.logLevel := p_logLevel;
        p_session_init.daysToKeep := p_daysToKeep;
        p_session_init.stepsToDo := p_stepsToDo;
        p_session_init.tabNameMaster := p_tabNameMaster;
    
        return new_session(p_session_init);
    end;

	--------------------------------------------------------------------------

    function NEW_SESSION(p_processName varchar2, p_logLevel PLS_INTEGER, p_tabNameMaster varchar2 default 'LILA_LOG') return number
    as
        p_session_init t_session_init;
    begin
        p_session_init.processName := p_processName;
        p_session_init.logLevel := p_logLevel;
        p_session_init.daysToKeep := null;
        p_session_init.stepsToDo := null;
        p_session_init.tabNameMaster := p_tabNameMaster;
    
        return new_session(p_session_init);
    end;


    -- Opens/starts a new logging session.
    -- The returned process id must be stored within the calling procedure because it is the reference
    -- which is recommended for all following actions (e.g. CLOSE_SESSION, DEBUG, SET_PROCESS_STATUS).
    function NEW_SESSION(p_processName varchar2, p_logLevel PLS_INTEGER, p_daysToKeep number, p_tabNameMaster varchar2 default 'LILA_LOG') return number
    as
        p_session_init t_session_init;
    begin
        p_session_init.processName := p_processName;
        p_session_init.logLevel := p_logLevel;
        p_session_init.daysToKeep := p_daysToKeep;
        p_session_init.stepsToDo := null;
        p_session_init.tabNameMaster := p_tabNameMaster;
    
        return new_session(p_session_init);
    end;
    
    --------------------------------------------------------------------------
    -- Avoid throttling 
	--------------------------------------------------------------------------
    function waitForResponse(
        p_signalName   IN varchar2, 
        p_signalMsg    IN varchar2,
        p_registerName IN varchar2, 
        p_timeoutSec   IN number
    ) return varchar2
    as
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_msg       VARCHAR2(1800);
        l_status    PLS_INTEGER;
    begin
        -- Prüfung auf Throttling (10-Sekunden-Sperre)
        IF (SYSTIMESTAMP - g_last_signal_time) > INTERVAL '10' SECOND THEN
            DBMS_ALERT.REGISTER(p_registerName);
            DBMS_ALERT.SIGNAL(p_signalName, p_signalMsg);
            COMMIT; -- Signal für andere Sessions sichtbar machen
            
            DBMS_ALERT.WAITONE(p_registerName, l_msg, l_status, p_timeoutSec);
            DBMS_ALERT.REMOVE(p_registerName);
            
            g_last_signal_time := SYSTIMESTAMP;
            
            -- Falls Timeout (status 1), geben wir einen Hinweis zurück
            IF l_status = 1 THEN
                l_msg := 'TIMEOUT';
            END IF;
        ELSE
            -- Kennung für: "Signal wurde wegen Throttling übersprungen"
            l_msg := 'THROTTLED';
        END IF;
    
        COMMIT; -- Autonome Transaktion abschließen
        return l_msg;
        
    exception
        when others then
            rollback;
            -- Im Fehlerfall sicherheitshalber das Register entfernen, 
            -- falls es oben bereits registriert wurde
            BEGIN DBMS_ALERT.REMOVE(p_registerName); EXCEPTION WHEN OTHERS THEN NULL; END;
            return 'ERROR: ' || SQLERRM;
    end;

	--------------------------------------------------------------------------

    function waitForSignal(
        p_signalName varchar2, 
        p_signalMsg varchar2,
        p_registerName varchar2, p_timeoutSec number
    ) return PLS_INTEGER
    as
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_msg       VARCHAR2(1800);
        l_status    PLS_INTEGER := -1;
    begin
        IF (SYSTIMESTAMP - g_last_signal_time) > INTERVAL '10' SECOND THEN
            DBMS_ALERT.REGISTER(p_registerName);
            DBMS_ALERT.SIGNAL(p_signalName, p_signalMsg);
            COMMIT;
            DBMS_ALERT.WAITONE(p_registerName, l_msg, l_status, p_timeoutSec);
            DBMS_ALERT.REMOVE(p_registerName);
            g_last_signal_time := SYSTIMESTAMP;
        END IF;
        commit;
        return l_status;
        
    exception
        when others then
            rollback;
            return 1;
    end;
    
    --------------------------------------------------------------------------
    
    FUNCTION GET_LATEST_CONFIG(p_timeout_sec IN NUMBER DEFAULT 5) RETURN CLOB IS
        l_report    CLOB;
        l_line      VARCHAR2(120) := RPAD('-', 100, '-') || CHR(10);
        l_sql       VARCHAR2(2000);
        l_cursor    SYS_REFCURSOR;
        l_response  VARCHAR2(1800);
        l_json_doc   VARCHAR2(2000);
        -- Variablen für die Spalten
        v_f_millis  NUMBER;
        v_f_log     NUMBER;
        v_f_proc    NUMBER;
        v_f_mon     NUMBER;
        v_m_factor  NUMBER;
        v_m_max     NUMBER;
    BEGIN
        -- B. Header für den Report
        l_report := l_line || ' LATEST ACTIVE CONFIGURATION REPORT' || CHR(10) || l_line;
        
        l_response := waitForResponse('LILA_REQUEST_CONFIG', 'LILA_RESPONSE_CONFIG', 'REQUEST_FROM_' || USER, p_timeout_sec);
        CASE
            WHEN l_response = 'TIMEOUT' THEN
                l_report := l_report || '-- Warnung: Instanz antwortet nicht (Timeout). Zeige alten Tabellenstand.' || CHR(10);
                
            WHEN l_response = 'THROTTLED' THEN
                l_report := l_report || '-- Info: Daten sind noch aktuell (10s Throttling aktiv).' || CHR(10);
                
            WHEN l_response LIKE 'ERROR%' THEN
                l_report := l_report || '-- Fehler: ' || l_response || CHR(10);
            else
            -- Erfolgsfall: JSON parsen
            l_json_doc := '{' || l_response || '}';
            BEGIN
                SELECT j.*
                INTO v_f_log, v_f_millis, v_f_proc, v_f_mon, v_m_factor, v_m_max
                FROM JSON_TABLE(l_json_doc, '$'
                    COLUMNS (
                        f_log    NUMBER PATH '$.FLUSH_LOG_THRESHOLD',
                        f_millis NUMBER PATH '$.FLUSH_MILLIS_THRESHOLD',
                        f_proc   NUMBER PATH '$.FLUSH_PROCESS_THRESHOLD',
                        f_mon    NUMBER PATH '$.FLUSH_MONITOR_THRESHOLD',
                        m_factor NUMBER PATH '$.MONITOR_ALERT_THRESHOLD_FACTOR',
                        m_max    NUMBER PATH '$.MAX_ENTRIES_PER_MONITOR_ACTION'
                    )
                ) j;

                l_report := l_report || 
                    RPAD('FLUSH_LOG_THRESHOLD', 35) || ': ' || v_f_log || CHR(10) ||
                    RPAD('FLUSH_MILLIS_THRESHOLD', 35) || ': ' || v_f_millis || CHR(10) ||
                    RPAD('FLUSH_PROCESS_THRESHOLD', 35) || ': ' || v_f_proc || CHR(10) ||
                    RPAD('FLUSH_MONITOR_THRESHOLD', 35) || ': ' || v_f_mon || CHR(10) ||
                    RPAD('MONITOR_FACTOR', 35) || ': ' || v_m_factor || CHR(10) ||
                    RPAD('MONITOR_MAX', 35) || ': ' || v_m_max || CHR(10);
                    
            EXCEPTION
                WHEN OTHERS THEN
                    l_report := l_report || '-- Fehler: bei Verarbeitung der Antwort: ' || SQLERRM || CHR(10);
            END;
        end case;

        l_report := l_report || l_line;
        RETURN l_report;
        
    EXCEPTION
        WHEN OTHERS THEN
            l_report := l_report || 'ERROR: Could not read configuration from ' || CONFIG_TABLE || CHR(10) || SQLERRM || CHR(10);

    END;

    -------------------------------------------------------------------------
    
    FUNCTION LIST_ACTIVE_SESSIONS(p_timeout_sec IN NUMBER DEFAULT 5) RETURN CLOB IS
        l_report    CLOB;
        l_line      VARCHAR2(200) := RPAD('-', 120, '-') || CHR(10);
        
        -- Variablen für den dynamischen Cursor
        l_cursor    SYS_REFCURSOR;
        l_sql       VARCHAR2(2000);
        
        -- Lokale Variablen für die Zeilenwerte (müssen mit der Tabellenstruktur matchen)
        v_id        NUMBER;
        v_name      VARCHAR2(100);
        v_start     TIMESTAMP;
        v_lvl       NUMBER;
        v_todo      NUMBER;
        v_done      NUMBER;
    BEGIN
        l_report := l_line || ' LATEST ACTIVE CONFIGURATION REPORT' || CHR(10) || l_line;
        
        case waitForSignal('LILA_REQUEST_PERSIST', 'LILA_DATA_PERSISTED', 'REQUEST_FROM_' || USER, p_timeout_sec)
            when 0 THEN
                l_report := l_report || '-- Status: Daten frisch von Instanz erhalten.' || CHR(10);
            when 1 then
                l_report := l_report || '-- Warnung: Instanz antwortet nicht (Timeout). Zeige alten Tabellenstand.' || CHR(10);
            when -1 then
                l_report := l_report || '-- Info: Lese Tabelle direkt (10s Throttling aktiv).' || CHR(10);
        end case;
    
        -- 3. Header für den Report bauen
        l_report := l_report || l_line ||
                    RPAD('PROCESS_ID', 12) || ' | ' ||
                    RPAD('NAME', 20) || ' | ' ||
                    RPAD('START_TIME', 20) || ' | ' ||
                    RPAD('LVL', 4) || ' | ' ||
                    RPAD('TODO', 8) || ' | ' ||
                    RPAD('DONE', 8) || CHR(10) ||
                    l_line;
                                   
        
        -- Dynamisches SQL zusammenbauen
        -- Wir nutzen CONFIG_TABLE (deine Variable/Konstante für den Namen)
        l_sql := ' SELECT process_id, process_name, process_start, log_level, steps_todo, steps_done ' ||
                 ' FROM ' || CONFIG_TABLE ||
                 ' WHERE is_active = 1
                   ORDER BY process_name, process_start DESC';

        BEGIN
            OPEN l_cursor FOR l_sql;
            LOOP
                FETCH l_cursor INTO v_id, v_name, v_start, v_lvl, v_todo, v_done;
                EXIT WHEN l_cursor%NOTFOUND;
    
                l_report := l_report || 
                    RPAD(NVL(TO_CHAR(v_id), ' '), 12) || ' | ' ||
                    RPAD(NVL(SUBSTR(v_name, 1, 20), ' '), 20) || ' | ' ||
                    RPAD(NVL(TO_CHAR(v_start, 'DD.MM.YY HH24:MI'), ' '), 20) || ' | ' ||
                    RPAD(NVL(TO_CHAR(v_lvl), ' '), 4) || ' | ' ||
                    RPAD(NVL(TO_CHAR(v_todo), ' '), 8) || ' | ' ||
                    RPAD(NVL(TO_CHAR(v_done), ' '), 8) || CHR(10);
            END LOOP;
            CLOSE l_cursor;
            
        EXCEPTION
            WHEN OTHERS THEN
                l_report := l_report || 'ERROR: Table ' || CONFIG_TABLE || ' could not be read.' || CHR(10);
                IF l_cursor%ISOPEN THEN CLOSE l_cursor; END IF;
        END;

        
        l_report := l_report || l_line;        
        RETURN l_report;
    END;
   
    
    PROCEDURE IS_ALIVE
    as
        pProcessName number(19,0);
    begin
        pProcessName := new_session('LILA Life Check', logLevelDebug);
        debug(pProcessName, 'First Message of LILA');
        close_session(pProcessName, 1, 1, 'OK', 1);
    end;

END LILA;
