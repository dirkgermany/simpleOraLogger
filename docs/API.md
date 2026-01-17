# LILA API
<details>
<summary>Content</summary>

- [At First](#at-first)
- [Overview](#overview)
- [Log Session](#log-session)
  - [What it is](#what-it-is)
  - [Log Session Life Cycle](#log-session-life-cycle)
- [Log Tables](#log-tables)
- [Sequence](#sequence)
- [LOG Level](#log-level)
  - [Declaration of Log Levels](#declaration-of-log-levels)
- [Functions and Procedures](#functions-and-procedures)
  - [Session related Functions and Procedures](#session-related-functions-and-procedures)
    - [Function NEW_SESSION](#function-new_session)
    - [Procedure CLOSE_SESSION](#procedure-close_session)
    - [Procedure SET_PROCESS_STATUS](#procedure-set_process_status)
    - [Procedure SET_STEPS_TODO](#procedure-set_steps_todo)
    - [Procedure SET_STEPS_DONE](#procedure-set_steps_done)
    - [Procedure STEP_DONE](#procedure-step_done)
  - [Write Logs related Procedures](#write-logs-related-procedures)
    - [General Logging Procedures](#general-logging-procedures)
    - [Procedure LOG_DETAIL](#procedure-log_detail)

</details>

## At first
This documentation strives to be comprehensive and accurate.

The detailed nature of this document may give the impression that using LILA is complex and time-consuming and requires a correspondingly high level of training.

In fact, a few interface calls are all that is needed for comprehensive monitoring or logging. Existing program code for the processes to be monitored also requires only minor adjustments.
Nevertheless, for a basic understanding of LILA and smooth integration into your applications, I recommend reading my hopefully not too boring explanations below.
However, if you want to get started right away and don't want to waste time reading documentation, I recommend the sample application. If you look at the code of this application, you will probably already understand and be able to use the most important concepts of LILA.
And who knows, when you have a quiet moment, you might decide to take another look at this document after all.

## Overview
LILA is nothing more than a PL/SQL Package.

This package enables logging from other packages.
Different packages can use logging simultaneously from a single session and write to either dedicated or the same LOG table.
        
Even when using a shared LOG table, the LOG entries can be identified by process name and — in the case of multiple calls to the same process — by process IDs (filtered via SQL).
For reasons of clarity, however, the use of dedicated LOG tables could make sense.

There is exactly one log entry for each logging process in the so called *master table*.
Additional informations (error, warn, info, debug) about the process are written to the so called *detail table* (see [`Log Tables`](#log-tables)).
        
The LOG entries are persisted within encapsulated transactions. This means that logging is independent of the (missing) COMMIT of the calling processes.

## Log Session
The log session is a central concept within LILA and sets it apart from many other PL/SQL logging frameworks.

### What it is
*Why use a so called Log Session? What is it?*

First of all: don't panic! The term “log session” simply describes various dependencies and states of logging related to the calling process. Ultimately, a log session encapsulates the logging configuration tailored to the respective process (log level, log tables, counters for details, etc.).
A log session is **not** an additional database session, instance of a database process, or anything similar.

A Log Session accompanies the execution of a PL/SQL process. Just as each running instance of a process is unique, so too is each Log Session.

*Why can't LILA simply write directly to the log tables without a Log Session, like other logging frameworks? Wouldn't it be sufficient to differentiate using the process name, for example?*

LILA not only enables parallel logging from multiple processes, but also — as mentioned above — different configuration values for each process. The configuration values are part of a log session.

### Log Session Life Cycle
Ideally, the Log Session begins when the process starts and ends when the process ends.
**With the beginning** of a Log Session the one and only log entry is written to the *master table*.
**During** the Log Session this one log entry can be updated and additional informations can be written to the *detail table*.
**At the end** of a Log Session the log entry again can be updated.

Although the lack of a regular log session termination (e.g., due to an uncaught exception in the calling process) is technically unsound, it does not ultimately lead to any real problems. The only exception is that the end of the process is not logged.

Ultimately, all that is required for a complete life cycle is to call the NEW_SESSION function at the beginning of the session and the CLOSE_SESSION procedure at the end of the session.

## Log Tables
The logging takes place in two tables. Below, I distinguish between them by referring to them as the *master table* and the *detail table*.

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

### List of Functions and Procedures

| Name               | Type      | Description                         | Scope
| ------------------ | --------- | ----------------------------------- | -------
| [`NEW_SESSION`](#function-new_session) | Function  | Opens a new log session | Log Session
| [`CLOSE_SESSION`](#procedure-close_session) | Procedure | Ends a log session | Log Session
| [`SET_PROCESS_STATUS`](#procedure-set_process_status) | Procedure | Sets the state of the log status | Log Session
| [`SET_STEPS_TODO`](#procedure-set_steps_todo) | Procedure | Sets the required number of actions | Log Session
| [`SET_STEPS_DONE`](#procedure-set_steps_todo) | Procedure | Sets the number of completed actions | Log Session
| [`STEP_DONE`](#procedure-step_done) | Procedure | Increments the counter of completed steps | Log Session
| [`INFO`](#general-logging-procedures) | Procedure | Writes INFO log entry               | Detail Logging
| [`DEBUG`](#general-logging-procedures) | Procedure | Writes DEBUG log entry              | Detail Logging
| [`WARN`](#general-logging-procedures) | Procedure | Writes WARN log entry               | Detail Logging
| [`ERROR`](#general-logging-procedures) | Procedure | Writes ERROR log entry              | Detail Logging
| [`LOG_DETAIL`](#procedure-log_detail) | Procedure | Writes log entry with any log level | Detail Logging
| [`PROCEDURE IS_ALIVE`](#procedure-is-alive) | Procedure | Excecutes a very simple logging session | Test


### Shortcuts for parameter requirement
* <a id="M"> **M**andatory</a>
* <a id="O"> **O**ptional</a>
* <a id="N"> **N**ullable</a>

### Session related Functions and Procedures
Whenever the record in the *master table* is changed, the value of the field last_update will be updated.
This mechanism is supports the monitoring features.

#### Function NEW_SESSION
The NEW_SESSION function starts the logging session for a process. Two function signatures are available for different scenarios.

*Option 1*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processName | VARCHAR2| freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_logLevel | NUMBER | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_daysToKeep | NUMBER | max. age of entries in days; if not NULL, all entries older than p_daysToKeep and whose process name = p_processName (not case sensitive) are deleted | [`N`](#n)
| p_tabNamePrefix | VARCHAR2 | optional prefix of the LOG table names (see above) | [`O`](#o)

*Option 2*
| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processName | VARCHAR2| freely selectable name for identifying the process; is written to *master table* | [`M`](#m)
| p_logLevel | NUMBER | determines the level of detail in *detail table* (see above) | [`M`](#m)
| p_stepsToDo | NUMBER | defines how many steps must be done during the process | [`M`](#m)
| p_daysToKeep | NUMBER | max. age of entries in days; if not NULL, all entries older than p_daysToKeep and whose process name = p_processName (not case sensitive) are deleted | [`N`](#n)
| p_tabNamePrefix | VARCHAR2 | optional prefix of the LOG table names (see above) | [`O`](#o)

**Returns**
Type: NUMBER
Description: The new process ID; this ID is required for subsequent calls in order to be able to assign the LOG calls to the process

**Syntax and Examples**
```sql
-- Syntax
---------
FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_daysToKeep NUMBER, p_tabNamePrefix VARCHAR2 DEFAULT 'LILA_PROCESS')
FUNCTION NEW_SESSION(p_processName VARCHAR2, p_logLevel NUMBER, p_stepsToDo NUMBER, p_daysToKeep NUMBER, p_tabNamePrefix VARCHAR2 DEFAULT 'LILA_PROCESS')

-- Usage
--------
-- Option 1
-- No deletion of old entries, log table name is 'LILA_PROCESS'
gProcessId := lila.new_session('my application', lila.logLevelWarn, null);
-- keep entries which are not older than 30 days
gProcessId := lila.new_session('my application', lila.logLevelWarn, 30);
-- use another log table name
gProcessId := lila.new_session('my application', lila.logLevelWarn, null, 'MY_LOG_TABLE');

-- Option 2
-- likely Option 1 but with information about the steps to be done (100)
gProcessId := lila.new_session('my application', lila.logLevelWarn, 100, null);
gProcessId := lila.new_session('my application', lila.logLevelWarn, 100, null, 'MY_LOG_TABLE');
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
#### Procedure SET_STEPS_TODO
Updates the number of required steps during the process in the log entry of the *master table*.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsToDo | NUMBER | defines how many steps must be done during the process | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE SET_STEPS_TODO(p_processId NUMBER, p_stepsToDo NUMBER)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- updating only by a status represented by a number
lila.set_steps_todo(gProcessId, 100);
```

#### Procedure SET_STEPS_DONE
Updates the number of completed steps during the process in the log entry of the *master table*.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)
| p_stepsDone | NUMBER | shows how many steps of the process are already completed | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE SET_STEPS_DONE(p_processId NUMBER, p_stepsDone NUMBER)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- updating only by a status represented by a number
lila.set_steps_done(gProcessId, 99);
```

#### Procedure STEP_DONE
Increments the number of already completed steps in the log entry of the *master table*.

| Parameter | Type | Description | Required
| --------- | ---- | ----------- | -------
| p_processId | NUMBER | ID of the process to which the session applies | [`M`](#m)

**Syntax and Examples**
```sql
-- Syntax
---------
PROCEDURE STEP_DONE(p_processId NUMBER)

-- Usage
--------
-- assuming that gProcessId is the global stored process ID

-- something like a trigger
lila.step_done(gProcessId);
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

#### Procedure IS_ALIVE
Creates one entry in the *master table* and one in the *detail table*.

This procedure needs no parameters.
```sql
-- execute the following statement in sql window
execute lila.is_alive;
-- check data and note the process_id
select * from lila_process where process_name = 'LILA Life Check';
-- check details using the process_id
select * from lila_process_detail where process_id = <process id>;
```
