# LILA
[![Release](https://img.shields.io/github/v/release/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/releases/latest)
[![Lizenz](https://img.shields.io/github/license/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/blob/main/LICENSE)
[![Größe](https://img.shields.io/github/repo-size/dirkgermany/LILA-Logging)](https://https://github.com/dirkgermany/LILA-Logging)

## Content
- [About](#about)
- [Key features](#key-features)
- [Lightwight?](#lightwight)
- [Simplicity?](#simplicity)
- [Logging](#logging)
  - [How to log](#how-to-log)
- [Monitoring](#monitoring)
  - [How to monitor](#how-to-monitor)

## About
LILA **i**s **l**ogging **a**pplications. LILA is a lightwight logging framework. And a little bit more.

Written as a PL/SQL package for Oracle it enables other Oracle processes writing logs using a simple interface. LILA enables simultaneous and multiple logging from the same session or different sessions.
Because LILA provides information about the processes, it can be used directly for monitoring purposes without additional database queries.

LILA is developed by a developer who hates over-engineered tools. Focus: 5 minutes to integrate, 100% visibility.

Detailed information on setup and the API you will find in the [documentation folder](docs/).

## Key features
1. Simplicity
2. Lightwight
3. Parallel logging from one or multiple database sessions
4. Supports monitoring per SQL and API
5. Clear code for individual customizing
6. Intuitive API

## Lightwight?
LILA consists of a PL/SQL package, two tables and a sequence. That's it.

## Simplicity?
* Setting up LILA means creating a sequence and a package (refer [documentation file "setup.md"](docs/setup.md))
* Only a few API calls are necessary for the complete logging of a process (refer [documentation file "API.md"](docs/API.md))
* Analysing or monitoring your process requires simple sql statements or API requests

Have a look to the [sample application "learn_lila"](source/sample).

---
## Logging
LILA persists different informations about your processes.
To keep it easy the informations are stored in two tables:

1. The (leading) master table with informations about the process itself (the live-dashboard). Always exactly one record per process. This table frees you from complex queries such as “group by,” “max(timestamp),” etc., which you would otherwise have to run on thousands or millions of rows to see the current status of your process.

2. The table with typical detailed log informations (the process-history). This second table enables rapid monitoring because the constantly growing number of entries has no impact on the master table.

***Process informations***
* Process name
* Process ID
* Timestamps process_start
* Timestamp process_end
* Timestamp last_update (should be identical with timestamp process_end, if exists)
* Steps todo and steps done
* Any info
* (Last) status

***Detailed informations***
* Process ID
* Serial number
* Any info
* Log level
* Session time
* Session user
* Host name
* Error stack (when exception was thrown)
* Error backtrace (depends to log level)
* Call stack (depends to log level)

### How to log
A code snippet:
```sql
procedure MY_DEMO_PROC
as
  -- process ID related to your logging process
  lProcessId number(19,0);

begin
  -- begin a new logging session
  -- the last parameter refers to killing log entries which are older than the given number of days
  -- if this param is NULL, no log entry will be deleted
  lProcessId := lila.new_session('my application', lila.logLevelWarn, 30);

  -- write a log entry whenever you want
  lila.info(lProcessId, 'Start');
  -- for more details...
  lila.debug(lProcessId, 'Function A');
  -- e.g. informations when an exception was raised
  lila.error(lProcessId, 'I made a fault');

  -- also you can change the status during your process runs
  lila.set_process_status(lProcessId, 1, 'DONE');

  -- last but not least end the logging session
  -- opional you can set the numbers of steps to do and steps done 
  lila.close_session(lProcessId, 100, 99, 'DONE', 1);

end MY_DEMO_PROC;

```
---

## Monitoring
Monitor your processes according to your requirements:
* Real-time Progress: Query the master table for a single-row snapshot of any running process (steps_todo, steps_done, status, timestamps).
* Deep Dive (Details): Query the detail table for the full chronological history and error stack of a process.
* API Access: Use the built-in getter functions to retrieve status and progress directly within your PL/SQL logic or UI components.

### How to monitor
Three options:

#### Real-time Progress
**Live-dashboard data**
```sql
SELECT id, status, last_update, ... FROM lila_process WHERE process_name = ... (provides the current status of the process)
```
>| ID | PROCESS_NAME   | PROCESS_START         | PROCESS_END           | LAST_UPDATE           | STEPS_TO_DO | STEPS_DONE | STATUS | INFO
>| -- | ---------------| --------------------- | --------------------- | --------------------- | ----------- | ---------- | ----- | ------
>| 1  | my application | 12.01.26 18:17:51,... | 12.01.26 18:18:53,... | 12.01.26 18:18:53,... | 100         | 99         | 2     | ERROR



#### Deep Dive
**Historical data**
```sql
SELECT * FROM lila_process_detail WHERE process_id = ...
```

>| PROCESS_ID | NO | INFO           | LOG_LEVEL | SESSION_TIME    | SESSION_USER | HOST_NAME | ERR_STACK        | ERR_BACKTRACE    | ERR_CALLSTACK
>| ---------- | -- | -------------- | --------- | --------------- | ------------ | --------- | ---------------- | ---------------- | ---------------
>| 1          | 1  | Start          | INFO      | 13.01.26 10:... | SCOTT        | SERVER1   | NULL             | NULL             | NULL
>| 1          | 2  | Function A     | DEBUG     | 13.01.26 11:... | SCOTT        | SERVER1   | NULL             | NULL             | "--- PL/SQL ..." 
>| 1          | 3  | I made a fault | ERROR     | 13.01.26 12:... | SCOTT        | SERVER1   | "--- PL/SQL ..." | "--- PL/SQL ..." | "--- PL/SQL ..."


#### API
The API provides all process data which belong to the process_id (see [Logging](#logging)).
```sql
...
FUNCTION getStatus(p_processId NUMBER) RETURNS VARCHAR2
...
lProcessStatus := lila.get_process_status(p_processId);
lProcessInfo := lila.get_process_info(p_processId);
lStepsDone := lila.get_steps_done(p_processId);
...
return 'ID = ' || id || '; Status: ' || lProcessStatus || '; Info: ' || lProcessInfo || '; Steps completed: ' || lStepsDone;
```
```sql
SELECT my_app.getStatus(1) proc_status FROM dual;
> ID = 1; Status: OK; Info: 'just working'; Steps completed: 42
```
