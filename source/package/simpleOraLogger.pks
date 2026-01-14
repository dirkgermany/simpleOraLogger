create or replace PACKAGE SO_LOG AS

    /* Complete Doc and last version see https://github.com/dirkgermany/simpleOraLogger */

    -- =========
    -- Log Level
    -- =========
    logLevelSilent  constant number := 0;
    logLevelError   constant number := 1;
    logLevelWarn    constant number := 2;
    logLevelInfo    constant number := 4;
    logLevelDebug   constant number := 8;
    
    ------------------------------
    -- Life cycle of a log session
    ------------------------------
    function  NEW_SESSION(p_processName varchar2, p_logLevel number, p_daysToKeep number, p_tabNamePrefix varchar2 default 'log_process') return number;
    procedure CLOSE_SESSION(p_processId number, p_stepsToDo number, p_stepsDone number, p_processInfo varchar2, p_status number);
    
    ---------------------------------
    -- Update the status of a process
    ---------------------------------
    procedure SET_PROCESS_STATUS(p_processId number, p_status number);
    procedure SET_PROCESS_STATUS(p_processId number, p_status number, p_processInfo varchar2);
    
    ------------------
    -- Logging details
    ------------------
    procedure INFO(p_processId number, p_stepInfo varchar2);
    procedure DEBUG(p_processId number, p_stepInfo varchar2);
    procedure WARN(p_processId number, p_stepInfo varchar2);
    procedure ERROR(p_processId number, p_stepInfo varchar2);
    
    procedure LOG_DETAIL(p_processId number, p_stepInfo varchar2, p_logLevel number);

    ----------
    -- Testing
    ----------
    -- feel free
    procedure insertProcess (p_tabName varchar2, p_processId number, p_logLevel number);
    function test(p_processId number) return varchar2;

END SO_LOG;
