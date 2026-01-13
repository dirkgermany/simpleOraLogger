# simpleOraLogger API

## Overview
simpleOraLogger is nothing more than a PL/SQL Package.
To shorten the procedures and functions the package is named SO_LOG (package and body).

This package enables logging from other packages.
Different packages can use logging simultaneously from a single session and write to either dedicated or the same LOG table.
        
Even when using a shared LOG table, the LOG entries can be identified by process name and — in the case of multiple calls to the same process — by process IDs (filtered via SQL).
For reasons of clarity, however, the use of dedicated LOG tables is recommended.
        
The LOG entries are persisted within encapsulated transactions. This means that logging is independent of the (missing) COMMIT of the calling processes.

## LOG Tables
Logging takes place in two tables. Here I distinguish them by '1' and '2'.

Table '1' is the leading table and contains the started processes, their names, and status. There is exactly one entry in this table for each process and log session.

The entries in Table 2 contain further details corresponding to the entries in Table 1.

Both tables have standard names.
At the same time, the name of table '1' is the so-called prefix for table '2'.
        
* The default name for table '1' is LOG_PROCESS.
* The default name for table '2' is LOG_PROCESS_DETAIL
       
The name of table '1' can be customized; for table '2', the 
selected name of table '1' is added as a prefix and _DETAIL is appended.
    
Example:
Selected name '1' = MY_LOG_TABLE

Set name '2' is automatically = MY_LOG_TABLE_DETAIL

## Sequence
Logging uses a sequence to assign process IDs. The name of the sequence is SEQ_LOG.

## Log Level
Depending on the selected log level, additional information is written to table ‘2’ (_DETAIL).
        
To do this, the selected log level must be >= the level implied in the logging call.

>logLevelSilent -> No details are written to table '2'
>
>logLevelError  -> Calls to the ERROR() procedure are taken into account
>
>logLevelWarn   -> Calls to the WARN() and ERROR() procedures are taken into account
>
>logLevelInfo   -> Calls to the INFO(), WARN(), and ERROR() procedures are taken into account
>
>logLevelDebug  -> Calls to the DEBUG(), INFO(), WARN(), and ERROR() procedures are taken into account

### Declaration of Log Levels
```sql
logLevelSilent  constant number := 0;
logLevelError   constant number := 1;
logLevelWarn    constant number := 2;
logLevelInfo    constant number := 4;
logLevelDebug   constant number := 8;
```
    
## Functions and Procedures
| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| NEW_SESSION [`NEW_SESSION`](####new_session) | Function  | Opens a new log session             | Log Session
| CLOSE_SESSION      | Procedure | Ends a log session                  | Log Session
| SET_PROCESS_STATUS | Procedure | Sets the state of the log status    | Log Session
| INFO               | Procedure | Writes INFO log entry               | Detail Logging
| DEBUG              | Procedure | Writes DEBUG log entry              | Detail Logging
| WARN               | Procedure | Writes WARN log entry               | Detail Logging
| ERROR              | Procedure | Writes ERROR log entry              | Detail Logging
| LOG_DETAIL         | Procedure | Writes log entry with any log level | Detail Logging

 procedure INFO(p_processId number, p_stepInfo varchar2);
    procedure DEBUG(p_processId number, p_stepInfo varchar2);
    procedure WARN(p_processId number, p_stepInfo varchar2);
    procedure ERROR(p_processId number, p_stepInfo varchar2);
    
### Session Handling
    -- (m) = mandatory
    -- (o) = optional
    -- (n) = NULL is allowed

#### NEW_SESSION


```sql    
function  NEW_SESSION(p_processName varchar2, p_logLevel number, p_daysToKeep number, p_tabNamePrefix varchar2 default 'log_process') return number;
-- (m) p_processName   : freely selectable name for identifying the process; is written to table ‘1’
-- (m) p_logLevel      : determines the level of detail in table ‘2’ (see above)
-- (n) p_daysToKeep    : max. age of entries in days; if not NULL, all entries older than p_daysToKeep
--                       and whose process name = p_processName (not case sensitive) are deleted
-- (o) p_tabNamePrefix : optional prefix of the LOG table names (see above)
--
-- return number       : the process ID; this ID is required for subsequent calls in order to be able to assign the LOG calls to the process
```      
    procedure CLOSE_SESSION(p_processId number, p_stepsToDo number, p_stepsDone number, p_processInfo varchar2, p_status number);
      -- (m) p_processId     : ID of the process to which the session applies
      -- (n) p_stepsToDo     : Number of work steps that would have been necessary for complete processing
      --                       This value must be managed by the calling package
      -- (n) p_stepsDone     : Number of work steps that were actually processed
      --                       This value must be managed by the calling package
      -- (n) p_processInfo   : Final information about the process (e.g., a readable status)
      -- (n) p_status        : Final status of the process (freely selected by the calling package)

### Life Cycle of a LOG SESSION
The NEW_SESSION function starts and the CLOSE_SESSION method ends a LOG session.

Calling both is important to ensure correct logging.
Regardless of this, logging is also possible without CLOSE_SESSION, for example, if the calling process is terminated prematurely or unexpectedly due to an error.    

    
    ---------------------------------
    -- Update the status of a process
    ---------------------------------
    -- As mentioned at the beginning, there is only one entry in table ‘1’ for a logging session and the corresponding process.
    -- The status of the process can be set using the following two procedures:
    
    procedure SET_PROCESS_STATUS(p_processId number, p_status number);
    -- (m) p_processId       : ID of the process to which the session applies
    -- (m) p_status          : Current status of the process (freely selected by the calling packet)
    
    procedure SET_PROCESS_STATUS(p_processId number, p_status number, p_processInfo varchar2);
    -- (m) p_processId       : ID of the process to which the session applies
    -- (m) p_status          : Current status of the process (freely selected by the calling packet)
    -- (m) p_processInfo     : Current information about the process (e.g. a readable status)
      
    
    ------------------
    -- Logging details
    ------------------
    -- The following log methods encapsulate writing to table “2” depending on
    -- the session-related log level set with the NEW_SESSION function.
    -- 
    -- These methods should be used for logging details, as this ensures that
    -- necessary logging is guaranteed and unnecessary logging is avoided.
    
    -- The standard-logging procedures use the same parameters:
    -- (m) p_processId     : ID of the process to which the session applies
    -- (m) p_stepInfo      : Free text with information about the process

    procedure INFO(p_processId number, p_stepInfo varchar2);
    procedure DEBUG(p_processId number, p_stepInfo varchar2);
    procedure WARN(p_processId number, p_stepInfo varchar2);
    procedure ERROR(p_processId number, p_stepInfo varchar2);
    
    -- Forces the writing of log entries independent to the general log level
    procedure LOG_DETAIL(p_processId number, p_stepInfo varchar2, p_logLevel number);
    -- (m) p_processId     : ID of the process to which the session applies
    -- (m) p_stepInfo      : Free text with information about the process
    -- (m) p_logLevel      : This log level is written into the detail table



    ----------
    -- Testing
    ----------
    -- feel free
    procedure insertProcess (p_tabName varchar2, p_processId number, p_logLevel number);
    function test(p_processId number) return varchar2;
