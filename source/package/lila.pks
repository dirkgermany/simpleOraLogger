create or replace PACKAGE LILA AS
    /* Complete Doc and last version see https://github.com/dirkgermany/LILA-Logging/docs */
LILA_VERSION constant varchar2(20) := 'v1.3.0';

    -- =========
    -- Log Level
    -- =========
    logLevelSilent      CONSTANT PLS_INTEGER := 0;
    logLevelError       CONSTANT PLS_INTEGER := 1;
    logLevelWarn        CONSTANT PLS_INTEGER := 2;
    logLevelMonitor     CONSTANT PLS_INTEGER := 3;
    logLevelInfo        CONSTANT PLS_INTEGER := 4;
    logLevelDebug       CONSTANT PLS_INTEGER := 8;
    
    -- ==================
    -- Codes and Messages
    -- ==================
    TXT_ACK_OK       CONSTANT VARCHAR2(30) := 'SERVER_ACK_OK';
    NUM_ACK_OK       CONSTANT PLS_INTEGER  := 1000;
    TXT_ACK_DECLINE  CONSTANT VARCHAR2(30) := 'SERVER_ACK_DECLINE';
    NUM_ACK_DECLINE  CONSTANT PLS_INTEGER  := 1001;
    TXT_ACK_SHUTDOWN CONSTANT VARCHAR2(30) := 'SERVER_ACK_SHUTDOWN';
    NUM_ACK_SHUTDOWN CONSTANT PLS_INTEGER  := 1010;
    TXT_PING_ECHO    CONSTANT VARCHAR2(30) := 'PING_ECHO';
    NUM_PING_ECHO CONSTANT PLS_INTEGER  := 100;
    TXT_SERVER_INFO    CONSTANT VARCHAR2(30) := 'SERVER_INFO';
    NUM_SERVER_INFO CONSTANT PLS_INTEGER  := 101;
    
    -- ================================
    -- Record representing process data
    -- ================================
    TYPE t_process_rec IS RECORD (
        id              NUMBER(19,0),
        process_name    varchar2(100),
        log_level       PLS_INTEGER,
        process_start   TIMESTAMP,
        process_end     TIMESTAMP,
        last_update     TIMESTAMP,
        steps_todo      PLS_INTEGER,
        steps_done      PLS_INTEGER,
        status          PLS_INTEGER,
        info            CLOB,
        tabNameMaster   VARCHAR2(100)
    );

    TYPE t_session_init IS RECORD (
        processName VARCHAR2(100),
        logLevel PLS_INTEGER,
        stepsToDo PLS_INTEGER,
        daysToKeep PLS_INTEGER,
        tabNameMaster VARCHAR2(100) DEFAULT 'LILA_LOG'
    );


    ------------------------------
    -- Life cycle of a log session
    ------------------------------
    FUNCTION NEW_SESSION(p_session_init t_session_init) RETURN NUMBER;
    FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_tabNameMaster VARCHAR2 default 'LILA_LOG') RETURN NUMBER;
    FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_daysToKeep NUMBER, p_tabNameMaster VARCHAR2 default 'LILA_LOG') RETURN NUMBER;
    FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel PLS_INTEGER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_tabNameMaster VARCHAR2 DEFAULT 'LILA_LOG') RETURN NUMBER;
    PROCEDURE CLOSE_SESSION(p_processId NUMBER);
    PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_processInfo VARCHAR2, p_status PLS_INTEGER);
    PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_stepsDone NUMBER, p_processInfo VARCHAR2, p_status PLS_INTEGER);
    PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_stepsToDo NUMBER, p_stepsDone NUMBER, p_processInfo VARCHAR2, p_status PLS_INTEGER);

    ---------------------------------
    -- Update the status of a process
    ---------------------------------
    PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status PLS_INTEGER);
    PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status PLS_INTEGER, p_processInfo VARCHAR2);
    PROCEDURE SET_STEPS_TODO(p_processId NUMBER, p_stepsToDo NUMBER);
    PROCEDURE SET_STEPS_DONE(p_processId NUMBER, p_stepsDone NUMBER);
    PROCEDURE STEP_DONE(p_processId NUMBER);

    -------------------------------
    -- Request process informations
    -------------------------------
    FUNCTION GET_STEPS_DONE(p_processId NUMBER) RETURN PLS_INTEGER;
    FUNCTION GET_STEPS_TODO(p_processId NUMBER) RETURN PLS_INTEGER;
    FUNCTION GET_PROCESS_START(p_processId NUMBER) RETURN TIMESTAMP;
    FUNCTION GET_PROCESS_END(p_processId NUMBER) RETURN TIMESTAMP;
    FUNCTION GET_PROCESS_STATUS(p_processId NUMBER) RETURN PLS_INTEGER;
    FUNCTION GET_PROCESS_INFO(p_processId NUMBER) RETURN VARCHAR2;
    FUNCTION GET_PROCESS_DATA(p_processId NUMBER) RETURN t_process_rec;

    ------------------
    -- Logging details
    ------------------
    PROCEDURE INFO(p_processId NUMBER, p_logText VARCHAR2);
    PROCEDURE DEBUG(p_processId NUMBER, p_logText VARCHAR2);
    PROCEDURE WARN(p_processId NUMBER, p_logText VARCHAR2);
    PROCEDURE ERROR(p_processId NUMBER, p_logText VARCHAR2);
    
    -------------
    -- Monitoring
    -------------
    PROCEDURE MARK_STEP(p_processId NUMBER, p_actionName VARCHAR2, p_timestamp TIMESTAMP DEFAULT NULL);
    FUNCTION GET_METRIC_AVG_DURATION(p_processId NUMBER, p_actionName VARCHAR2) return NUMBER;
    FUNCTION GET_METRIC_STEPS(p_processId NUMBER, p_actionName VARCHAR2) return NUMBER;
    

    FUNCTION CREATE_SERVER(p_password varchar2) RETURN VARCHAR2;
    procedure START_SERVER(p_pipeName varchar2, p_password varchar2);
    FUNCTION SERVER_NEW_SESSION(p_payload varchar2) RETURN NUMBER;

    procedure SERVER_SEND_ANY_MSG(p_processId number, p_message varchar2);
    procedure SERVER_SHUTDOWN(p_processId number, p_pipeName varchar2, p_password varchar2);
    procedure SHUTDOWN_ALL_SERVERS;

    
    -- Schwellenwerte für den Schutz der SGA (besonders 23ai Free)
    C_THROTTLE_LIMIT    CONSTANT PLS_INTEGER := 10000; -- Max Logs pro Intervall
    C_THROTTLE_INTERVAL CONSTANT NUMBER      := 1000;   -- Mindestzeit in Millis für Limit
    C_THROTTLE_SLEEP    CONSTANT NUMBER      := 1.0;   -- Dauer der Atempause



    ----------
    -- Testing
    ----------
    -- Check if LILA works
    PROCEDURE IS_ALIVE;
END LILA;
