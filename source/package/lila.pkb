create or replace PACKAGE BODY LILA AS
        
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
        process_is_dirty    BOOLEAN,
        last_process_flush  TIMESTAMP,
        tabName_master      VARCHAR2(100)
    );

    -- Table for several processes
    TYPE t_session_tab IS TABLE OF t_session_rec;
    g_sessionList t_session_tab := null;
    
    -- Indexes for lists
    TYPE t_idx IS TABLE OF PLS_INTEGER INDEX BY BINARY_INTEGER;
    v_indexSession t_idx;
    
    -- Private Liste im Speicher (PGA)
    -- Index ist die Session-ID, Wert ist beliebig (hier Boolean)
    TYPE t_remote_sessions IS TABLE OF BOOLEAN INDEX BY BINARY_INTEGER;
    g_remote_sessions t_remote_sessions;

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

    TYPE t_dirty_queue IS TABLE OF BOOLEAN INDEX BY BINARY_INTEGER;
    g_dirty_queue t_dirty_queue;
    
    ---------------------------------------------------------------
    -- General Variables
    ---------------------------------------------------------------

    -- ALERT Registration
    g_isAlertRegistered BOOLEAN := false;
    g_alertCode_Flush CONSTANT varchar2(25) := 'LILA_ALERT_FLUSH_CFG';
    g_alertCode_Read  CONSTANT varchar2(25) := 'LILA_ALERT_READ_CFG';
    
    g_pipeName      CONSTANT VARCHAR2(30) := 'LILA_REQUEST_PIPE';

    -- general Flush Time-Duration
    g_flush_millis_threshold PLS_INTEGER            := 1500; 
    g_flush_log_threshold PLS_INTEGER               := 100;
    g_flush_process_threshold PLS_INTEGER           := 100;
    g_max_entries_per_monitor_action PLS_INTEGER    := 1000; -- Round Robin: Max. Anzahl Einträge für eine Aktion je Action
    g_flush_monitor_threshold PLS_INTEGER           := 100; -- Max. Anzahl Monitoreinträge für das Flush
    g_monitor_alert_threshold_factor NUMBER         := 2.0; -- Max. Ausreißer in der Dauer eines Verarbeitungsschrittes
    
    -- Throttling for SIGNALs
    g_last_signal_time TIMESTAMP := SYSTIMESTAMP - INTERVAL '1' DAY;
    
    TYPE code_map_t IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(30);
    g_response_codes code_map_t;
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
    procedure sync_log(p_processId number, p_force boolean default false);
    procedure sync_monitor(p_processId number, p_force boolean default false);
    procedure sync_process(p_processId number, p_force boolean default false);
    
    ---------------------------------------------------------------
    -- Antwort Codes stabil vereinheitlichen
    ---------------------------------------------------------------
    PROCEDURE initialize_map IS
    BEGIN
        IF g_response_codes.COUNT = 0 THEN
            g_response_codes(TXT_ACK_SHUTDOWN) := NUM_ACK_SHUTDOWN;
            g_response_codes(TXT_ACK_OK)       := NUM_ACK_OK;
        END IF;
    END initialize_map;
    
    FUNCTION get_serverCode(p_txt VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        initialize_map; -- Stellt sicher, dass die Map befüllt ist
        
        IF g_response_codes.EXISTS(p_txt) THEN
            RETURN g_response_codes(p_txt);
        ELSE
            RETURN -1; -- Oder eine Exception werfen
        END IF;
    END;
    
    -- Interne Prüfung
    FUNCTION is_remote(p_processId IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN g_remote_sessions.EXISTS(p_processId);
    END is_remote;

    
    --------------------------------------------------------------------------
    -- Calc Timestamp as key for requests 
	--------------------------------------------------------------------------
    function getRequestKey return varchar2
    as
    begin
 
    return 'LILA->' || SYS_CONTEXT('USERENV', 'SID') || '-' || TO_CHAR(
        (EXTRACT(DAY FROM (sys_extract_utc(SYSTIMESTAMP) - TO_TIMESTAMP('1970-01-01', 'YYYY-MM-DD'))) * 86400000) + 
        TO_NUMBER(TO_CHAR(sys_extract_utc(SYSTIMESTAMP), 'SSSSSFF3')),
        'FM999999999999999'
    );
    end;
    
    --------------------------------------------------------------------------
    -- Avoid throttling 
	--------------------------------------------------------------------------
    function waitForResponse(
        p_request       in varchar2, -- Wird für die Zuordnung/Verzweigung im Server benötigt
        p_payload       IN varchar2, 
        p_timeoutSec    IN PLS_INTEGER
    ) return varchar2
    as
        l_msg       VARCHAR2(1800);
        l_status    PLS_INTEGER;
        l_statusReceive PLS_INTEGER;
        l_clientChannel  varchar2(50);
        l_header    varchar2(100);
        l_meta      varchar2(100);
        l_data      varchar2(1500);
    begin
dbms_output.enable();        
        l_clientChannel := getRequestKey;
        
        l_header := '"header":{"request":"' || p_request || '", "response":"' || l_clientChannel ||'"}';
        l_meta  := '"meta":{"param":"value"}';
        l_data  := '"payload":' || p_payLoad;
        l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
        
        DBMS_PIPE.PACK_MESSAGE(l_msg);
        l_status := DBMS_PIPE.SEND_MESSAGE(g_pipeName, timeout => 3);
        l_status := DBMS_PIPE.RECEIVE_MESSAGE(l_clientChannel, timeout => p_timeoutSec);
        IF l_statusReceive = 0 THEN
            DBMS_PIPE.UNPACK_MESSAGE(l_msg);
            dbms_output.put_line(l_msg);
        END IF;
        
        IF l_statusReceive = 1 THEN RETURN 'TIMEOUT'; END IF;
        return l_msg;
    end;
	--------------------------------------------------------------------------

    
    procedure sendNoWait(
        p_request       in varchar2, -- Wird für die Zuordnung/Verzweigung im Server benötigt
        p_payload       IN varchar2, 
        p_timeoutSec    IN number
    )
    as        
        l_msg       VARCHAR2(1800);
        l_header    varchar2(140);
        l_meta      varchar2(140);
        l_data      varchar2(1500);
        l_status    PLS_INTEGER;
    begin        
        l_header := '"header":{"msg_type":"API_CALL", "request":"' || p_request || '"}';
        l_meta  := '"meta":{"param":"value"}';
        l_data  := '"payload":' || p_payLoad;
        
        l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';
        DBMS_PIPE.PACK_MESSAGE(p_payload);
        l_status := DBMS_PIPE.SEND_MESSAGE(g_pipeName, timeout => 0);

        IF l_status != 0 THEN
            -- Optional: Fehlerbehandlung, falls Pipe voll
            NULL; 
        END IF;
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
            null;
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
--            if should_raise_error(p_processId) then
DBMS_OUTPUT.PUT_LINE('CRITICAL: Persistierung fehlgeschlagen: ' || SQLERRM);
        RAISE; -- Das wird den Server stoppen, aber dir den Grund zeigen!
                raise;
--            end if;

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
        
        -- In write_to_log_buffer
        g_sessionList(v_idx).log_dirty_count := nvl(g_sessionList(v_idx).log_dirty_count, 0) + 1;
        -- ID in die Dirty-Queue werfen
        g_dirty_queue(p_processId) := TRUE;

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
    --------------------------------------------------------------------
    -- Alle Dirty Einträge für alle Sessions wegschreiben
    --------------------------------------------------------------------
    PROCEDURE SYNC_ALL_DIRTY(p_force BOOLEAN DEFAULT FALSE) 
    IS
        v_id      BINARY_INTEGER;
        v_next_id BINARY_INTEGER;
        v_idx     PLS_INTEGER;
    BEGIN
        -- Wir starten am Anfang der "Dreckigen Liste"
        v_id := g_dirty_queue.FIRST;
        
        WHILE v_id IS NOT NULL LOOP
            -- 1. Zeiger auf das nächste Element sichern, bevor wir evtl. DELETE machen
            v_next_id := g_dirty_queue.NEXT(v_id);
            
            -- 2. Index der Session-Metadaten holen
            -- (Wir nutzen v_indexSession, um sicherzustellen, dass die Session noch existiert)
            IF v_indexSession.EXISTS(v_id) THEN
                v_idx := v_indexSession(v_id);
    
                -- 3. Synchronisation aller drei Bereiche für diesen Prozess
                -- Falls p_force=TRUE (z.B. Shutdown), wird sofort geschrieben.
                -- Falls FALSE, entscheiden die Prozeduren anhand ihrer Thresholds.
                sync_log(v_id, p_force);
                sync_monitor(v_id, p_force);
                sync_process(v_id, p_force);
                
                -- 4. Überprüfung: Ist die Session jetzt "sauber"?
                -- Nur wenn ALLE Buffer für diesen Prozess auf 0 sind, 
                -- darf er aus der Queue fliegen.
                IF p_force OR (
                       nvl(g_sessionList(v_idx).log_dirty_count, 0) = 0 
                   AND nvl(g_sessionList(v_idx).monitor_dirty_count, 0) = 0
                   AND NOT g_sessionList(v_idx).process_is_dirty
                ) THEN
                    g_dirty_queue.DELETE(v_id);
                END IF;
            ELSE
                -- Session existiert nicht mehr in der Master-Liste? 
                -- Dann sofort aus der Queue entfernen (Cleanup).
                g_dirty_queue.DELETE(v_id);
            END IF;
            
            -- 5. Zum nächsten Element springen
            v_id := v_next_id;
        END LOOP;
    END;

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
        g_sessionList(v_idx).monitor_dirty_count := nvl(g_sessionList(v_idx).monitor_dirty_count, 0) + 1;
        g_dirty_queue(p_processId) := TRUE;
    
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
        sync_all_dirty;
        
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
        g_sessionList(v_new_idx).monitor_dirty_count := 0;
        g_sessionList(v_new_idx).log_dirty_count := 0;

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
        v_idx            pls_integer;
        v_now            constant timestamp := systimestamp;
        v_ms_since_flush number;
    begin
        -- 1. Sicherstellen, dass die Session im Server/Standalone bekannt ist
        if not v_indexSession.EXISTS(p_processId) then
            return;
        end if;
    
        v_idx := v_indexSession(p_processId);
    
        -- 2. Zeit seit dem letzten Master-Update berechnen
        if g_sessionList(v_idx).last_process_flush is null then
            v_ms_since_flush := g_flush_millis_threshold + 1;
        else
            v_ms_since_flush := get_ms_diff(g_sessionList(v_idx).last_process_flush, v_now);
        end if;
    
        -- 3. Die "Smarte" Flush-Bedingung
        -- Wir flushen nur, wenn FORCE (z.B. Session-Ende), der Zeit-Threshold erreicht ist
        -- ODER wenn dieser spezifische Prozess als "dirty" markiert wurde.
        if p_force 
           or (g_sessionList(v_idx).process_is_dirty AND v_ms_since_flush >= g_flush_millis_threshold)
           or (p_force = false AND v_ms_since_flush >= (g_flush_millis_threshold * 10)) -- Safety Sync
        then
            -- Nur schreiben, wenn es auch wirklich Änderungen im Cache gibt
            if g_process_cache.EXISTS(p_processId) then
                persist_process_record(g_process_cache(p_processId));            
                
                -- Reset der prozessspezifischen Steuerungsdaten
                g_sessionList(v_idx).process_is_dirty   := FALSE;
                g_sessionList(v_idx).last_process_flush := v_now;
            end if;
        end if;
    
    exception
        when others then
            if should_raise_error(p_processId) then
                raise;
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
    
    procedure log_anyRemote(
        p_processId number, 
        p_level number,
        p_logText varchar2,
        p_errStack varchar2,
        p_errBacktrace varchar2,
        p_errCallstack varchar2
    )
    as
        l_payload varchar2(32767); -- Puffer für den JSON-String
    begin
        -- Erzeugung des JSON-Objekts
        select json_object(
            'process_id'    value p_processId,
            'level'         value p_level,
            'log_text'      value p_logText,
            'err_stack'     value p_errStack,
            'err_backtr'    value p_errBacktrace,
            'err_callstack' value p_errCallstack
            returning varchar2
        )
        into l_payload from dual;
        sendNoWait('LOG_ANY', l_payload, 5);
                
    EXCEPTION
        WHEN OTHERS THEN
            if should_raise_error(p_processId) then
                raise;
            end if;

    end;

    
	--------------------------------------------------------------------------

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
        if is_remote(p_processId) then
dbms_output.enable();
dbms_output.put_line('DEBUG: log_any remote path for ID ' || p_processId);
            log_anyRemote(p_processId, p_level, p_logText, SUBSTRB(p_errStack, 1, 400), SUBSTRB(p_errBacktrace, 1, 400), SUBSTRB(p_errCallstack, 1, 400));
            return;
        end if;

        -- Hier nur weiter, wenn nicht remote
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
            SYNC_ALL_DIRTY(true);
       
        else
            sync_all_dirty;
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

            g_sessionList(v_indexSession(p_processId)).process_is_dirty := TRUE;
            g_dirty_queue(p_processId) := TRUE; -- Damit SYNC_ALL_DIRTY die Session sieht
            SYNC_ALL_DIRTY;
            
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
            SYNC_ALL_DIRTY;
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
            SYNC_ALL_DIRTY;
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
            SYNC_ALL_DIRTY(true);

--            if  logLevelSilent <= g_sessionList(v_indexSession(p_processId)).log_level then
                v_idx := v_indexSession(p_processId);
                g_sessionList(v_idx).steps_done := p_stepsDone;        
                persist_close_session(p_processId,  g_sessionList(v_idx).tabName_master, p_stepsToDo, p_stepsDone, p_processInfo, p_status);
                
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
		if p_session_init.logLevel > logLevelSilent then -- and p_session_init.daysToKeep is not null then
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
        
    function extractFromJsonStr(p_json_doc varchar2, jsonPath varchar2) return varchar2
    as
    begin
        return JSON_VALUE(p_json_doc, '$.' || jsonPath);
    end;
    
    --------------------------------------------------------------------------
    
    function extractFromJsonNum(p_json_doc varchar2, jsonPath varchar2) return number
    as
    begin
        return JSON_VALUE(p_json_doc, '$.' || jsonPath returning NUMBER);
    exception 
        when others then return null; -- Oder Fehlerbehandlung
    end;
   
	--------------------------------------------------------------------------
    
    function extractClientChannel(p_json_doc varchar2) return varchar2
    as
    begin
        return JSON_VALUE(p_json_doc, '$.header.response');
    end;        
    
    --------------------------------------------------------------------------
    
    function extractClientRequest(p_json_doc varchar2) return varchar2
    as
    begin
        return JSON_VALUE(p_json_doc, '$.header.request');
    end;
    
	--------------------------------------------------------------------------
    
    procedure doRemote_logAny(p_message varchar2)
    as
        l_processId number;
        l_level number;
        l_logText varchar2(1000);
        l_errStack varchar2(1000);
        l_errBacktrace varchar2(1000);
        l_errCallstack varchar2(1000);
        l_payload varchar2(1600);
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');
        l_processId := extractFromJsonNum(l_payload, 'process_id');
        l_level := extractFromJsonNum(l_payload, 'level');
        l_logText := extractFromJsonStr(l_payload, 'log_text');
        l_errStack := extractFromJsonStr(l_payload, 'err_stack');
        l_errBacktrace := extractFromJsonStr(l_payload, 'err_backtr');
        l_errCallstack := extractFromJsonStr(l_payload, 'err_callstack');
        
        log_any(l_processId, l_level, l_logText, l_errStack, l_errBacktrace, l_errCallstack);
    end;
    
    procedure doRemote_newSession(p_clientChannel varchar2, p_message VARCHAR2)
    as
        l_processId number;
        l_payload varchar2(1600);
        l_session_init t_session_init;
        l_status PLS_INTEGER;
    begin
        l_payload := JSON_QUERY(p_message, '$.payload');
        l_processId := extractFromJsonStr(l_payload, 'process_id');
        l_session_init.logLevel    := extractFromJsonNum(l_payload, 'log_level');
        l_session_init.stepsToDo   := extractFromJsonNum(l_payload, 'steps_todo');
        l_session_init.daysToKeep  := extractFromJsonNum(l_payload, 'days_to_keep');
        l_session_init.tabNameMaster := extractFromJsonStr(l_payload, 'tabname_master');        

        l_processId := NEW_SESSION(l_session_init);
        DBMS_PIPE.RESET_BUFFER; -- Koffer leeren
        DBMS_PIPE.PACK_MESSAGE('{"process_id":' || l_processId || '}');        
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 1);
    end;    
    
	-------------------------------------------------------------------------- 
    procedure SERVER_SEND_EXIT(p_message varchar2)
    as
        l_response varchar2(1000);
    begin
        l_response := waitForResponse(
            p_request       => 'EXIT',
            p_payload       => p_message,
            p_timeoutSec    => 5
        );
        dbms_output.put_line('Antwort vom Server: ' || l_response);
    end;

    
    procedure SERVER_SEND_ANY_MSG(p_message varchar2)
    as
        l_response varchar2(1000);
    begin
        l_response := waitForResponse(
            p_request       => 'ANY_MSG',
            p_payload       => p_message,
            p_timeoutSec    => 5
        );
    end;
    
	--------------------------------------------------------------------------    
    
    FUNCTION SERVER_NEW_SESSION(p_payload varchar2) RETURN NUMBER
    as
        l_ProcessId number(19,0) := -500;   
        l_payload   varchar2(1000);
        l_response  varchar2(100);        
        jasonObj    JSON_OBJECT_T := JSON_OBJECT_T();
    begin        
        l_response := waitForResponse('NEW_SESSION', p_payload, 5);
        
        CASE
            WHEN l_response = 'TIMEOUT' THEN
                l_ProcessId := -110;
            WHEN l_response = 'THROTTLED' THEN
                l_ProcessId := -120;                
            WHEN l_response LIKE 'ERROR%' THEN
                l_ProcessId := - 100;
            else
            -- Erfolgsfall: JSON parsen
            l_ProcessId := extractFromJsonNum(l_response, 'process_id');
        end case;

        -- Nur valide IDs registrieren
        IF l_ProcessId > 0 THEN
            g_remote_sessions(l_ProcessId) := TRUE;
        END IF;
        RETURN l_ProcessId;
        
    EXCEPTION
        WHEN OTHERS THEN
        return -200;
    end;
    
	--------------------------------------------------------------------------
    
    PROCEDURE DUMP_BUFFER_STATS AS
        v_key VARCHAR2(100);
        v_log_total NUMBER := 0;
        v_mon_total NUMBER := 0;
    BEGIN
    dbms_output.enable();
    
        -- 1. Logs zählen
        v_key := g_log_groups.FIRST;
        WHILE v_key IS NOT NULL LOOP
            v_log_total := v_log_total + g_log_groups(v_key).COUNT;
            v_key := g_log_groups.NEXT(v_key);
        END LOOP;
    
        -- 2. Monitore zählen
        v_key := g_monitor_groups.FIRST;
        WHILE v_key IS NOT NULL LOOP
            v_mon_total := v_mon_total + g_monitor_groups(v_key).COUNT;
            v_key := g_monitor_groups.NEXT(v_key);
        END LOOP;
    
        DBMS_OUTPUT.PUT_LINE('--- LILA BUFFER DIAGNOSE ---');
        DBMS_OUTPUT.PUT_LINE('Sessions in Queue: ' || g_dirty_queue.COUNT);
        DBMS_OUTPUT.PUT_LINE('Gepufferte Logs:   ' || v_log_total);
        DBMS_OUTPUT.PUT_LINE('Gepufferte Monit.: ' || v_mon_total);
        DBMS_OUTPUT.PUT_LINE('Master-Cache:      ' || g_process_cache.COUNT);
    END;
    
    --------------------------------------------------------------------------
    function packServerResp(p_serverMsgTxt varchar2) return varchar2
    as
        l_serverCodeNum PLS_INTEGER;
        l_header varchar2(100);
        l_meta   varchar2(100);
        l_data   varchar2(100);
        l_msg    varchar2(500);
    begin
    
        l_serverCodeNum := get_serverCode(p_serverMsgTxt);
        l_header := '"header":{"msg_type":"SERVER_RESPONSE", "server_version":"' || LILA_VERSION || '"}';
        l_meta   := '"meta":{"param":"value"}';
        l_data   := '"payload":{"server_message":"' || TXT_ACK_SHUTDOWN || '", ' || l_serverCodeNum;
        
        l_msg := '{' || l_header || ', ' || l_meta || ', ' || l_data || '}';

        return l_msg;
    end;
    
	--------------------------------------------------------------------------
    
    PROCEDURE handleServerExit(p_clientChannel varchar2, p_serverMsgNum varchar2)
    as
        l_status    PLS_INTEGER;
    begin
        DBMS_PIPE.PACK_MESSAGE(packServerResp(p_serverMsgNum));
        l_status := DBMS_PIPE.SEND_MESSAGE(p_clientChannel, timeout => 2);
        dbms_output.put_line('Exit Signal gesetzt, antworte an ' || p_clientChannel);
        
        IF l_status = 0 THEN
            dbms_output.put_line('Antwort an Client gesendet.');
        ELSE
            dbms_output.put_line('Fehler beim Senden der Antwort: ' || l_status);
        END IF;                    
    end;
    
	--------------------------------------------------------------------------

    PROCEDURE START_SERVER
    as
v_key VARCHAR2(100); 
        l_clientChannel  varchar2(30);
        l_message       VARCHAR2(32767);
        l_status    PLS_INTEGER;
        l_timeout   NUMBER := 10; -- Timeout nach Sekunden Warten auf Nachricht
        l_request   VARCHAR2(100);
        l_json_doc  VARCHAR2(2000);
        
        l_localSession number(19,0);
        l_dummyRes PLS_INTEGER;
        l_exitSignal BOOLEAN := FALSE;
        l_stop_server_exception EXCEPTION;
    begin
dbms_output.enable();
        l_localSession := NEW_SESSION('LILA_SERVER', logLevelDebug);
    
        -- Pipe erstellen (Public oder Private, Kapazität hier 1MB für High-Load)
        l_dummyRes := DBMS_PIPE.REMOVE_PIPE(g_pipeName);
        l_dummyRes := DBMS_PIPE.CREATE_PIPE(pipename => g_pipeName, maxpipesize => 1048576, private => false);
        DBMS_PIPE.PURGE(g_pipeName); 
        
        LOOP -- DIES IST DIE ENDLOSSCHLEIFE
            -- Warten auf die nächste Nachricht (Timeout in Sekunden)
            l_status := DBMS_PIPE.RECEIVE_MESSAGE(g_pipeName, timeout => l_timeout);
            IF l_status = 0 THEN
            BEGIN 
                DBMS_PIPE.UNPACK_MESSAGE(l_message);
                l_clientChannel := extractClientChannel(l_message);
                l_request := extractClientRequest(l_message);
                                
                CASE l_request
                    WHEN 'EXIT' then
                        handleServerExit(l_clientChannel, TXT_ACK_SHUTDOWN); 
                        l_exitSignal := TRUE;

                    WHEN 'ANY_MSG' then
                        null;
                        
                    WHEN 'NEW_SESSION' THEN
                        doRemote_newSession(l_clientChannel, l_message);

                    WHEN 'LOG_ANY' then
                        doRemote_logAny(l_message);

                    ELSE 
                        -- Unbekanntes Tag loggen
                        warn(l_localSession, 'Unknown request: ' || l_request);
                END CASE;

                EXCEPTION
                    WHEN l_stop_server_exception THEN
                        -- Diese Exception wird NICHT hier abgefangen, 
                        -- sondern nach außen an den Loop gereicht.
                        RAISE;
                        
                    WHEN OTHERS THEN
                        -- WICHTIG: Fehler loggen, aber die Schleife NICHT verlassen!
                        ERROR(l_localSession, 'Kritischer Fehler bei Verarbeitung eines Kommandos: ' || SQLERRM);
                END;
            
            ELSIF l_status = 1 THEN
                -- Timeout erreicht. Passiert, wenn 10 Sekunden kein Signal kam.
                -- Housekeeping
                dbms_output.put_line('Housekeeping');
                SYNC_ALL_DIRTY;
            end if;
            
            EXIT when l_exitSignal;
        END LOOP;
        
        -- es könnten noch dirty buffered Einträge existieren
        sync_all_dirty(true);

        v_key := TO_CHAR(l_localSession);        
        IF g_log_groups.EXISTS(v_key) THEN
            DBMS_OUTPUT.PUT_LINE('Logs im Buffer für '||v_key||': '|| lila.g_log_groups(v_key).COUNT);
        ELSE
            DBMS_OUTPUT.PUT_LINE('Keine Logs im Buffer für Server mit Prozess-ID: '||v_key);
        END IF;
        
        -- abschließende Analyse der Buffer-Zustände
        DUMP_BUFFER_STATS;

        -- Dieser Teil wird nie erreicht, solange die DB-Session aktiv ist
        close_session(l_localSession);
        
    EXCEPTION
    WHEN l_stop_server_exception THEN
        -- Hier landen wir nur, wenn der Server gezielt beendet werden soll
        dbms_output.put_line('Err: ' || sqlerrm);
        ERROR(l_localSession, 'Kritischer Fehler bei Verarbeitung eines Kommandos: ' || SQLERRM);
        CLOSE_SESSION(l_localSession);
    
    WHEN OTHERS THEN
        dbms_output.put_line('Err: ' || sqlerrm);
    end;

    ------------------------------------------------------------------------
    
    PROCEDURE IS_ALIVE
    as
        pProcessName number(19,0);
    begin
        pProcessName := new_session('LILA Life Check', logLevelDebug);
        debug(pProcessName, 'First Message of LILA');
        close_session(pProcessName, 1, 1, 'OK', 1);
    end;

END LILA;
