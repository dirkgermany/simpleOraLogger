create or replace PACKAGE LILA AS

    /* Complete Doc and last version see https://github.com/dirkgermany/LILA */

    -- =========
    -- Log Level
    -- =========
    logLevelSilent  CONSTANT NUMBER := 0;
    logLevelError   CONSTANT NUMBER := 1;
    logLevelWarn    CONSTANT NUMBER := 2;
    logLevelInfo    CONSTANT NUMBER := 4;
    logLevelDebug   CONSTANT NUMBER := 8;

    ------------------------------
    -- Life cycle of a log session
    ------------------------------
    FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_TabNameMaster VARCHAR2 default 'LILA_LOG') RETURN NUMBER;
    FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_daysToKeep NUMBER, p_TabNameMaster VARCHAR2 default 'LILA_LOG') RETURN NUMBER;
    FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_TabNameMaster VARCHAR2 DEFAULT 'LILA_LOG') RETURN NUMBER;
    PROCEDURE CLOSE_SESSION(p_processId NUMBER);
    PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_stepsToDo NUMBER, p_stepsDone NUMBER, p_processInfo VARCHAR2, p_status NUMBER);

    ---------------------------------
    -- Update the status of a process
    ---------------------------------
    PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status NUMBER);
    PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status NUMBER, p_processInfo VARCHAR2);
    PROCEDURE SET_STEPS_TODO(p_processId NUMBER, p_stepsToDo NUMBER);
    PROCEDURE SET_STEPS_DONE(p_processId NUMBER, p_stepsDone NUMBER);
    PROCEDURE STEP_DONE(p_processId NUMBER);

    -------------------------------
    -- Request process informations
    FUNCTION GET_STEPS_DONE(p_processId NUMBER) RETURN NUMBER;
    FUNCTION GET_STEPS_TODO(p_processId NUMBER) RETURN NUMBER;
    FUNCTION GET_PROCESS_START(p_processId NUMBER) RETURN TIMESTAMP;
    FUNCTION GET_PROCESS_END(p_processId NUMBER) RETURN TIMESTAMP;
    FUNCTION GET_PROCESS_STATUS(p_processId NUMBER) RETURN NUMBER;
    FUNCTION GET_PROCESS_INFO(p_processId NUMBER) RETURN VARCHAR2;

    -------------------------------

    ------------------
    -- Logging details
    ------------------
    PROCEDURE INFO(p_processId NUMBER, p_stepInfo VARCHAR2);
    PROCEDURE DEBUG(p_processId NUMBER, p_stepInfo VARCHAR2);
    PROCEDURE WARN(p_processId NUMBER, p_stepInfo VARCHAR2);
    PROCEDURE ERROR(p_processId NUMBER, p_stepInfo VARCHAR2);

    PROCEDURE LOG_DETAIL(p_processId NUMBER, p_stepInfo VARCHAR2, p_logLevel NUMBER);

    ----------
    -- Testing
    ----------
    -- Check if LILA works
    PROCEDURE IS_ALIVE;

    -- feel free
    FUNCTION test(p_processId NUMBER) RETURN VARCHAR2;

END LILA;
