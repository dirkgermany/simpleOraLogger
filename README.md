# LILA

## Content
- [About](#about)
- [Simple?](#simple)
- [Logging](#logging)
- [Demo](#demo)

## About
LILA **i**s **l**ogging **a**pplications. LILA is a framework.
Written as a PL/SQL package it enables other PL/SQL processes writing logs using a simple interface. LILA enables simultaneous and multiple logging from the same session or different sessions.
Two key requirements of LILA are:
1. Simplicity of the interface
2. Simultaneous logging from one or multiple database sessions

Even though debugging informations can be written, LILA is primarily intended for monitoring (automated) PL/SQL processes (hereinafter referred to as the processes).

For easy monitoring log informations are written into two tables: one to see the status of your processes, one to see more details, e.g. if something went wrong.
Your processes can be identified by their names.

## Simple?
* Create Sequence and Package
  * Create Sequence by a simple statement (see statement in documentation)
  * Copy the package code to your database schema and compile
* Call the logging procedures/functions out of your PL/SQL code
* Check log entries in the log tables

## Logging
LILA monitors different informations about your processes.

***General informations***
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
### Check log entries
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

