# LILA API
<details>
<summary>Content</summary>

- [Overview](#overview)
- [LOG Tables](#log-tables)
- [Sequence](#sequence)
- [LOG Level](#log-level)
  - [Declaration of Log Levels](#declaration-of-log-levels)
- [Functions and Procedures](#functions-and-procedures)
  - [Session related Functions and Procedures](#session-related-functions-and-procedures)
    - [Function NEW_SESSION](#function-new_session)
    - [Procedure CLOSE_SESSION](#procedure-close_session)
    - [Procedure SET_PROCESS_STATUS](#procedure-set_process_status)
  - [Write Logs related Procedures](#write-logs-related-procedures)
    - [General Logging Procedures](#general-logging-procedures)
    - [Procedure LOG_DETAIL](#procedure-log_detail)

</details>

## Overview
LILA is nothing more than a PL/SQL Package.

This package enables logging from other packages.
Different packages can use logging simultaneously from a single session and write to either dedicated or the same LOG table.
        
Even when using a shared LOG table, the LOG entries can be identified by process name and — in the case of multiple calls to the same process — by process IDs (filtered via SQL).
For reasons of clarity, however, the use of dedicated LOG tables is recommended.
        
The LOG entries are persisted within encapsulated transactions. This means that logging is independent of the (missing) COMMIT of the calling processes.

## LOG Tables
Logging takes place in two tables. Here I distinguish them by *master table* and *detail table*.

Table *master table* is the leading table and contains the started processes, their names, and status. There is exactly one entry in this table for each process and log session.

The entries in *detail table* contain further details corresponding to the entries in Table 1.

Both tables have standard names.
At the same time, the name of the *master table* is the so-called prefix for the *detail table*.
        
* The default name for the *master table* is LILA_PROCESS.
* The default name for the *detail table* is LILA_PROCESS_DETAIL
       
The name of table *master table* can be customized; for *detail table*, the 
selected name of table *master table* is added as a prefix and _DETAIL is appended.
    
Example:
Selected name *master table* = MY_LOG_TABLE

Set name *detail table* is automatically = MY_LOG_TABLE_DETAIL

## Sequence
Logging uses a sequence to assign process IDs. The name of the sequence is SEQ_LILA_LOG.

## Log Level
Depending on the selected log level, additional information is written to the *detail table*.
        
To do this, the selected log level must be >= the level implied in the logging call.
* logLevelSilent -> No details are written to the *detail table*
* logLevelError  -> Calls to the ERROR() procedure are taken into account
* logLevelWarn   -> Calls to the WARN() and ERROR() procedures are taken into account
* logLevelInfo   -> Calls to the INFO(), WARN(), and ERROR() procedures are taken into account
* logLevelDebug  -> Calls to the DEBUG(), INFO(), WARN(), and ERROR() procedures are taken into account

If you want to suppress any logging, set logLevelSilent as active log level.

### Declaration of Log Levels
```sql
logLevelSilent  constant number := 0;
logLevelError   constant number := 1;
logLevelWarn    constant number := 2;
logLevelInfo    constant number := 4;
logLevelDebug   constant number := 8;
```
    
## Functions and Procedures
Shortcuts for parameter requirement:
* <a id="M"> Mandatory</a>
* <a id="O"> Optional</a>
* <a id="N"> Nullable</a>

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`NEW_SESSION`](#function-new_session) | Function  | Opens a new log session | Log Session
| [`CLOSE_SESSION`](#procedure-close_session) | Procedure | Ends a log session | Log Session, Session Handling
| [`SET_PROCESS_STATUS`](#procedure-set_process_status) | Procedure | Sets the state of the log status    | Log Session, Session Handling
| [`INFO`](#general-logging-procedures) | Procedure | Writes INFO log entry               | Detail Logging
| [`DEBUG`](#general-logging-procedures) | Procedure | Writes DEBUG log entry              | Detail Logging
| [`WARN`](#general-logging-procedures) | Procedure | Writes WARN log entry               | Detail Logging
| [`ERROR`](#general-logging-procedures) | Procedure | Writes ERROR log entry              | Detail Logging
| [`LOG_DETAIL`](#procedure-log_detail) | Procedure | Writes log entry with any log level | Detail Logging
| [`PROCEDURE IS_ALIVE`](#procedure-is-alive) | Procedure | Excecutes a very simple logging session | Test

### Session related Functions and Procedures
#### Function NEW_SESSION
The NEW_SESSION function starts the logging session for a process.
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processName | VARCHAR2| freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_logLevel | NUMBER | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_daysToKeep | NUMBER | max. age of entries in days; if not NULL, all entries older than p_daysToKeep and whose process name = p_processName (not case sensitive) are deleted | [`N`](#n)
| p_tabNamePrefix | VARCHAR2 | optional prefix of the LOG table names (see above) | [`O`](#o)

**Returns**
Type: NUMBER
Description: The new process ID; this ID is required for subsequent calls in order to be able to assign the LOG calls to the process

**Syntax and Examples**
```sql
-- Syntax
---------
FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_daysToKeep NUMBER, p_tabNamePrefix VARCHAR2 DEFAULT 'LOG_PROCESS')

-- Usage
--------
-- No deletion of old entries, log table name is 'LILA_PROCESS'
gProcessId := lila.new_session('my application', lila.logLevelWarn, null);
-- keep entries which are not older than 30 days
gProcessId := lila.new_session('my application', lila.logLevelWarn, 30);
-- use another log table name
gProcessId := lila.new_session('my application', lila.logLevelWarn, null, 'MY_LOG_TABLE');
```

#### Procedure CLOSE_SESSION
Ends a logging session with optional final informations. Two function signatures are available for different scenarios.
* Option 1 is a simple close without any additional information about the process.
* Option 2 allows adding various informations to the ending process.

*Option 1*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)

*Option 2*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsToDo | NUMBER | Number of work steps that would have been necessary for complete processing. This value must be managed by the calling package | [`N`](#n)
| p_stepsDone | NUMBER | Number of work steps that were actually processed. This value must be managed by the calling package | [`N`](#n)
| p_processInfo | VARCHAR2 | Final information about the process (e.g., a readable status) | [`N`](#n)
| p_status | NUMBER | Final status of the process (freely selected by the calling package) | [`N`](#n)

**Syntax and Examples**
```sql
-- Syntax
---------
-- Option 1
PROCEDURE CLOSE_SESSION(p_processId NUMBER)
-- Option 2
PROCEDURE CLOSE_SESSION(p_processId NUMBER, p_stepsToDo NUMBER, p_stepsDone NUMBER, p_processInfo VARCHAR2, p_status NUMBER)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- close without any information (e.g. when be set with SET_PROCESS_STATUS before)
lila.close_session(gProcessId);
-- close without informations about process steps
lila.close_session(gProcessId, null, null, 'Success', 1);
-- close with additional informations about steps
lila.close_session(gProcessId, 100, 99, 'Problem', 2);
```

#### Procedure SET_PROCESS_STATUS
Updates the status of a process.

As mentioned at the beginning, there is only one entry in the *master table* for a logging session and the corresponding process.
The status of the process can be set using the following two variants:

*Option 1 without info as text*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_status | NUMBER | Current status of the process (freely selected by the calling package) | [`M`](#m)

*Option 2 with additional info as text*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_status | NUMBER | Current status of the process (freely selected by the calling package) | [`M`](#m)
| p_processInfo | VARCHAR2 | Current information about the process (e.g., a readable status) | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
-- Option 1
PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status NUMBER)
-- Option 2
PROCEDURE SET_PROCESS_STATUS(p_processId NUMBER, p_status NUMBER, p_processInfo VARCHAR2)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- updating only by a status represented by a number
lila.set_process_status(gProcessId, 1);
-- updating by using an additional information
lila.set_process_status(gProcessId, 1, 'OK');
```

### Write Logs related Procedures
#### General Logging Procedures
The detailed log entries in *detail table* are written using various procedures.
Depending on the log level corresponding to the desired entry, the appropriate procedure is called.

The procedures have the same signatures and differ only in their names.
Their descriptions are therefore summarized below.

* Procedure ERROR: details are written if the debug level is one of
  - logLevelError
  - logLevelWarn
  - logLevelInfo
  - logLevelDebug
* Procedure WARN: details are written if the debug level is one of
  - logLevelWarn
  - logLevelInfo
  - logLevelDebug
* Procedure INFO: details are written if the debug level is one of
  - logLevelInfo
  - logLevelDebug
* Procedure DEBUG: details are written if the debug level is one of
  - logLevelDebug

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepInfo | VARCHAR2 | Free text with information about the process | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE ERROR(p_processId NUMBER, p_stepInfo VARCHAR2)
PROCEDURE WARN(p_processId NUMBER, p_stepInfo VARCHAR2)
PROCEDURE INFO(p_processId NUMBER, p_stepInfo VARCHAR2)
PROCEDURE DEBUG(p_processId NUMBER, p_stepInfo VARCHAR2)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- write an error
lila.error(gProcessId, 'Something happened');
-- write a debug information
lila.debug(gProcessId, 'Function was called');
```

#### Procedure LOG_DETAIL
Writes a LOG entry, regardless of the currently set LOG level.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepInfo | VARCHAR2 | Free text with information about the process | [`M`](#m)
| p_logLevel | NUMBER | This log level is written into the detail table | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE LOG_DETAIL(p_processId NUMBER, p_stepInfo VARCHAR2, p_logLevel NUMBER);

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- write a log record
lila.log_detail(gProcessId, 'I ignore the log level');
```
### Testing
Independent to other Packages you can check if LILA works in general.

#### PROCEDURE IS_ALIVE
Creates one entry in the *master table* and one in the detail table.

This procedure needs no parameters.
```sql
-- execute the following statement in sql window
execute lila.is_alive;
-- check data and note the process_id
select * from lila_process where process_name = 'LILA Life Check';
-- check details using the process_id
select * from lila_process_detail where process_id = <process id>;
```
