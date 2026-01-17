# LILA - LILA Integrated Logging Architecture
[![Release](https://img.shields.io/github/v/release/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/releases/latest)
[![Lizenz](https://img.shields.io/github/license/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/blob/main/LICENSE)
[![Größe](https://img.shields.io/github/repo-size/dirkgermany/LILA-Logging)](https://https://github.com/dirkgermany/LILA-Logging)
[![Sponsor](https://img.shields.io/badge/Sponsor-LILA-orange?style=flat-square&logo=github-sponsors)](https://github.com/sponsors/dirkgermany)



LILA is a lightweight logging and monitoring framework designed for Oracle PL/SQL applications. It provides a fast, concurrent way to track processes. Its simple API allows for seamless integration into existing applications with minimal overhead.

LILA utilizes autonomous transactions to ensure that all log entries are persisted, even if the main process performs a rollback.

LILA is developed by a developer who hates over-engineered tools. Focus: 5 minutes to integrate, 100% visibility.

## Content
- [Key features](#key-features)
- [Fast integration](#fast-integration)
- [Logging](#logging)
  - [How to log](#how-to-log)
- [Monitoring](#monitoring)
  - [How to monitor](#how-to-monitor)

## Key features
1. **Lightweight**: One Package, two Tables, one Sequence. That's it.
2. **Concurrent Logging**: Supports multiple, simultaneous log entries from the same or different sessions without blocking
7. **Monitoring**: You have the option to observe your applications via SQL or by the API
3. **Parallel Execution**: Designed for high-performance Oracle environments
4. **Data Integrity**: Uses autonomous transactions to guarantee log persistence regardless of the main transaction's outcome
5. **Smart Context Capture**: Automatically records ERR_STACK, ERR_BACKTRACE, and ERR_CALLSTACK based on the configured log level, providing deep insights for error analysis without manual overhead
8. **Optional self-cleaning**: Automatically purges expired logs per application during session start—no background jobs or schedulers required
6. **Version Compatibility**: Fully tested on the latest Oracle AI Database 26ai (2026)
7. **Small Footprint**: Under 700 lines of logical PL/SQL code. Easy to audit, fast to compile, and zero bloat

## Fast integration
* Setting up LILA means creating a sequence and a package (refer [documentation file "setup.md"](docs/setup.md))
* Only a few API calls are necessary for the complete logging of a process (refer [documentation file "API.md"](docs/API.md))
* Analysing or monitoring your process requires simple sql statements or API requests

Have a look to the [sample application "learn_lila"](source/sample).

---
## Logging
LILA persists different information about your processes.
For simplicity, all logs are stored in two tables.

1. The master table contains data about the process itself (the live-dashboard). Always exactly one record per process. This table frees you from complex queries such as “group by,” “max(timestamp),” etc., which you would otherwise have to run on thousands or millions of rows to see the current status of your process.

2. The table with typical detailed log information (the process-history). This second table enables rapid monitoring because the constantly growing number of entries has no impact on the master table.

***Process information***
* Process name
* Process ID
* Timestamps process_start
* Timestamp process_end
* Timestamp last_update (at end of your process identical with timestamp of process_end)
* Steps todo and steps done
* Any info
* (Last) status

***Detailed information***
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
  -- e.g. information when an exception was raised
  lila.error(lProcessId, 'An error occurred');

  -- also you can change the status during your process runs
  lila.set_process_status(lProcessId, 1, 'DONE');

  -- last but not least end the logging session
  -- optional you can set the numbers of steps to do and steps done 
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
The API provides all process data which belongs to the process_id (see [Logging](#logging)).
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

---
### Support the Project 💜
Do you find **lila-logging** useful? Consider sponsoring the project to support its ongoing development and long-term maintenance.

[![Beer](https://img.shields.io/badge/Buy%20me%20a%20beer-LILA-purple?style=for-the-badge&logo=buy-me-a-coffee)](https://github.com/sponsors/dirkgermany)


