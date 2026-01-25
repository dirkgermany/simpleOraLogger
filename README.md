# LILA - LILA Integrated Logging Architecture


[![Release](https://img.shields.io/github/v/release/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/releases/latest)
[![Status](https://img.shields.io/badge/Status-Production--Ready-brightgreen)](https://github.com/dirkgermany/LILA-Logging)
[![Lizenz](https://img.shields.io/github/license/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/blob/main/LICENSE)
[![Größe](https://img.shields.io/github/repo-size/dirkgermany/LILA-Logging)](https://https://github.com/dirkgermany/LILA-Logging)
[![Sponsor](https://img.shields.io/badge/Sponsor-LILA-purple?style=flat-square&logo=github-sponsors)](https://github.com/sponsors/dirkgermany)


<p align="center">
  <img src="images/lila-logging.svg" alt="Lila Logger Logo" width="300">
</p>

LILA is a lightweight logging and monitoring framework designed for Oracle PL/SQL applications. It provides a fast, concurrent way to track processes. Its simple API allows for seamless integration into existing applications with minimal overhead.

LILA utilizes autonomous transactions to ensure that all log entries are persisted, even if the main process performs a rollback.

LILA is developed by a developer who hates over-engineered tools. Focus: 5 minutes to integrate, 100% visibility.

## Content
- [Key features](#key-features)
- [Fast integration](#fast-integration)
- [Advantages](#advantages)
- [Logging](#logging)
  - [How to log](#how-to-log)
- [Monitoring](#monitoring)
  - [How to monitor](#how-to-monitor)

## Key features
1. **Lightweight**: One Package, two Tables, one Sequence. That's it!
2. **Concurrent Logging**: Supports multiple, simultaneous log entries from the same or different sessions without blocking
3. **Monitoring**: You have the option to observe your applications via SQL or via the API
4. **Data Integrity**: Uses autonomous transactions to guarantee log persistence regardless of the main transaction's outcome
5. **Smart Context Capture**: Automatically records ERR_STACK,  ERR_BACKTRACE, and ERR_CALLSTACK based on log level—deep insights with zero manual effort
6. **Optional self-cleaning**: Automatically purges expired logs per application during session start—no background jobs or schedulers required
7. **Future Ready**: Built for the latest Oracle 26ai (2026), and fully tested with existing 19c environment
8. **Small Footprint**:  ~1k lines of logical PL/SQL code ensures simple quality and security control, fast compilation, zero bloat and minimal Shared Pool utilization (reducing memory pressure and fragmentation)

---
## Fast integration
* Setting up LILA means creating a package by copy&paste (refer [documentation file "setup.md"](docs/setup.md))
* Only a few API calls are necessary for the complete logging of a process (refer [documentation file "API.md"](docs/API.md))
* Analysing or monitoring your process requires simple sql statements or API requests

>LILA comes ready to test right out of the box, so no custom implementation or coding is required to see the framework in action immediately after setup.
>Also please have a look to the sample applications 'learn_lila': https://github.com/dirkgermany/LILA-Logging/tree/main/demo/first_steps.

---
## Advantages
The following points complement the **Key Features** and provide a deeper insight into the architectural decisions and technical innovations of LILA.

### Technology
#### Autonomous Persistence
LILA strictly utilizes `PRAGMA AUTONOMOUS_TRANSACTION`. This guarantees that log entries and monitoring data are permanently stored in the database, even if the calling main transaction performs a `ROLLBACK` due to an error. This ensures the root cause remains available for post-mortem analysis.

#### Deep Context Insights
By leveraging the `UTL_CALL_STACK`, LILA automatically captures the exact program execution path. Instead of just logging a generic error, it documents the entire call chain, significantly accelerating the debugging process in complex, nested PL/SQL environments.

#### High-Performance Buffering
To minimize the impact on the main application’s overhead, LILA features an internal buffering system. Log writing is processed efficiently, offering a decisive performance advantage over simple, row-by-row logging methods, especially in high-load production environments.

#### Robust & Non-Invasive (Silent Mode)
LILA is designed to be "invisible." The framework ensures that an internal error during the logging process (e.g., table space issues or configuration errors) doesn't crash the calling application logic. Exceptions within LILA are caught and handled internally, prioritizing the stability of your business transaction over the logging activity itself.

#### Built-in Extensibility (Adapters)
LILA's decoupled architecture is designed for seamless integration with modern monitoring stacks. Its structured data format allows for the easy creation of adapters:
*   **Oracle APEX:** Use native SQL queries to power APEX Charts and Dashboards for real-time application monitoring.
*   **Grafana:** Connect LILA via **ORDS (Oracle REST Data Services)** to visualize performance trends and system health in Grafana dashboards.
*   **Custom Adapters:** The relational core can be extended for any REST-based or SQL-based reporting tool without modifying the core logging engine.

### High-Efficiency Monitoring

#### Real-Time Performance Metrics
LILA is more than just a logging tool. Using the `MARK_STEP` functionality, named actions can be monitored independently. The framework automatically tracks metrics **per action**:
*   **Step Duration:** Precise execution time for a specific action's segment.
*   **Average Duration:** Historical benchmarks to detect performance degradation per action.
*   **Step Counter:** Monitoring progress and iterations within a specific named workflow.

#### Intelligent Metric Calculation
Instead of performing expensive aggregations across millions of log records for every query, LILA uses an intelligent calculation mechanism. Metrics are updated incrementally, ensuring that monitoring dashboards (e.g., in Grafana, APEX, or Oracle Jet) remain highly responsive even with massive datasets.

### Core Strengths

#### Scalability & Cloud Readiness
By avoiding file system dependencies (`UTL_FILE`) and focusing on native database features, LILA is 100% compatible with **Oracle Autonomous Database** and optimized for scalable cloud infrastructures in 2026.

#### Developer Experience (DX)
LILA promotes a standardized error-handling and monitoring culture within development teams. Its easy-to-use API allows for a "zero-config" start, enabling developers to implement professional observability in just a few minutes. No complex DBA grants or extensive infrastructure preparations are required—just deploy the package and start logging immediately.

---
## Demo
Execute the following statement in the SQL editor (optionally activate dbms-output for your session beforehand):
```sql
exec lila.is_alive;
select * from lila_log;
```
If you have activated dbms output, you will receive an additional message there.

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

For comprehensive information, refer to [documentation file "monitoring.md"](docs/monitoring.md).

### How to monitor
Three options:

#### Real-time Progress
**Live-dashboard data**
```sql
SELECT id, status, last_update, ... FROM lila_log WHERE process_name = ... (provides the current status of the process)
```

>| ID | PROCESS_NAME   | PROCESS_START         | PROCESS_END           | LAST_UPDATE           | STEPS_TO_DO | STEPS_DONE | STATUS | INFO
>| -- | ---------------| --------------------- | --------------------- | --------------------- | ----------- | ---------- | ----- | ------
>| 1  | my application | 12.01.26 18:17:51,... | 12.01.26 18:18:53,... | 12.01.26 18:18:53,... | 100         | 99         | 2     | ERROR



#### Deep Dive
**Historical data**
```sql
SELECT * FROM lila_log_detail WHERE process_id = ...
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
Do you find **LILA** useful? Consider sponsoring the project to support its ongoing development and long-term maintenance.

[![Beer](https://img.shields.io/badge/Buy%20me%20a%20beer-LILA-purple?style=for-the-badge&logo=buy-me-a-coffee)](https://github.com/sponsors/dirkgermany)


