create or replace PACKAGE LILA AS

    /* Complete Doc and last version see https://github.com/dirkgermany/LILA */

    -- =========
    -- Log Level
    -- =========
    logLevelSilent  CONSTANT PLS_INTEGER := 0;
    logLevelError   CONSTANT PLS_INTEGER := 1;
    logLevelWarn    CONSTANT PLS_INTEGER := 2;
    logLevelInfo    CONSTANT PLS_INTEGER := 4;
    logLevelDebug   CONSTANT PLS_INTEGER := 8;
    
    -- ================================
    -- Record representing process data
    -- ================================
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


    ------------------------------
    -- Life cycle of a log session
    ------------------------------
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
    PROCEDURE INFO(p_processId NUMBER, p_stepInfo VARCHAR2);
    PROCEDURE DEBUG(p_processId NUMBER, p_stepInfo VARCHAR2);
    PROCEDURE WARN(p_processId NUMBER, p_stepInfo VARCHAR2);
    PROCEDURE ERROR(p_processId NUMBER, p_stepInfo VARCHAR2);

    PROCEDURE LOG_DETAIL(p_processId NUMBER, p_stepInfo VARCHAR2, p_logLevel PLS_INTEGER);

    ----------
    -- Testing
    ----------
    -- Check if LILA works
    PROCEDURE IS_ALIVE;

    -- feel free
    FUNCTION test(p_processId NUMBER) RETURN VARCHAR2;

END LILA;
