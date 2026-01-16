# LILA
[![Release](https://img.shields.io/github/v/release/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/releases/latest)
[![Lizenz](https://img.shields.io/github/license/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/blob/main/LICENSE)
[![Größe](https://img.shields.io/github/repo-size/dirkgermany/LILA-Logging)](https://github.com/dirkgermany/LILA-Logging/blob/main/LICENSE)

## Content
- [About](#about)
- [Key features](#key-features)
- [Lightwight?](#lightwight)
- [Simplicity?](#simplicity)
- [Logging](#logging)
- [Monitoring](#monitoring)
- [Demo](#demo)

## About
LILA **i**s **l**ogging **a**pplications. LILA is a lightwight logging framework. And a little bit more.

Written as a PL/SQL package for Oracle it enables other Oracle processes writing logs using a simple interface. LILA enables simultaneous and multiple logging from the same session or different sessions.
Because LILA provides information about the processes, it can be used directly for monitoring purposes without additional database queries.

Detailed information on setup and the API you will find in the [documentation folder](docs/).

## Key features
1. Simplicity
2. Lightwight
3. Parallel logging from one or multiple database sessions
4. Supports monitoring per API
5. Clear code for individual customizing
6. Intuitive API

## Lightwight?
LILA consists of a PL/SQL package, two tables and a sequence. That's it.

## Simplicity?
* Setting up LILA means creating a sequence and a package (refer [documentation file "setup.md"](docs/setup.md))
* Only a few API calls are necessary for the complete logging of a process (refer [documentation file "API.md"](docs/API.md))
* Analysing or monitoring your process requires simple sql statements or API requests

Have a look to the [sample application "learn_lila"](source/sample).

## Logging
LILA monitors different informations about your processes.

***Process informations***
* Process name
* Process ID
* Begin and Start
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

## Monitoring
The above process information can be read via the API interface.
* Process name
* Process ID
* Begin and Start
* Steps todo and steps done
* Info
* Status

## Demo
### Usage from your PL/SQL
```sql
procedure MY_DEMO_PROC
as
  -- global process ID related to your logging process
  gProcessId number(19,0);

begin
  -- begin a new logging session
  -- the last parameter refers to killing log entries which are older than the given number of days
  -- if this param is NULL, no log entry will be deleted
  gProcessId := lila.new_session('my application', lila.logLevelWarn, 30);

  -- write a log entry whenever you want
  lila.info(gProcessId, 'Start');
  -- for more details...
  lila.debug(gProcessId, 'Function A');
  -- e.g. informations when an exception was raised
  lila.error(gProcessId, 'I made a fault');

  -- also you can change the status during your process runs
  lila.set_process_status(1, 'DONE');

  -- last but not least end the logging session
  -- opional you can set the numbers of steps to do and steps done 
  lila.close_session(gProcessId, 100, 99, 'DONE', 1);

end MY_DEMO_PROC;
```
### Log entries per SQL
```sql
  -- main entries are written to the default log table LILA_PROCESS
  -- details are writte to the default detail log table LILA_PROCESS_DETAIL
  -- find out your process by its process name or look for the latest entry in the LILA_PROCESS

  -- general status of your process
  -- to shorten the output here in the text I simplified some values
  select * from LILA_PROCESS where PROCESS_NAME = 'my application';

  -- get details; the NO is the serial order of entries related to the process
  select * from LILA_PROCESS_DETAIL where process_id = 1 order by NO;
```

#### Result for table LILA_PROCESS
>| ID | PROCESS_NAME   | PROCESS_START         | PROCESS_END           | STEPS_TO_DO | STEPS_DONE | STATUS | INFO
>| -- | ---------------| --------------------- | --------------------- | ----------- | ---------- | ------ | -----
>| 1  | my application | 12.01.26 18:18:53,... | 12.01.26 18:18:53,... | 100         | 99         | 2      | ERROR

#### Result for table LILA_PROCESS_DETAIL
>| PROCESS_ID | NO | INFO           | LOG_LEVEL | SESSION_TIME    | SESSION_USER | HOST_NAME | ERR_STACK        | ERR_BACKTRACE    | ERR_CALLSTACK
>| ---------- | -- | -------------- | --------- | --------------- | ------------ | --------- | ---------------- | ---------------- | ---------------
>| 1          | 1  | Start          | INFO      | 13.01.26 10:... | SCOTT        | SERVER1   | NULL             | NULL             | NULL
>| 1          | 2  | Function A     | DEBUG     | 13.01.26 11:... | SCOTT        | SERVER1   | NULL             | NULL             | "--- PL/SQL ..." 
>| 1          | 3  | I made a fault | ERROR     | 13.01.26 12:... | SCOTT        | SERVER1   | "--- PL/SQL ..." | "--- PL/SQL ..." | "--- PL/SQL ..."

