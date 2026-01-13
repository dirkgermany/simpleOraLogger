# simpleOraLogger

## Content
- [About](#about)
- [Simple?](#simple)
- [Logging](#logging)
- [Demo](#demo)

## About
PL/SQL Package for simple logging of PL/SQL processes. Allows multiple and parallel logging out of the same session.

Even though debug informations can be written, simpleOraLogger is primarily intended for monitoring (automated) PL/SQL processes (hereinafter referred to as the processes).

For easy daily monitoring log informations are written into two tables: one to see the status of your processes, one to see more details, e.g. something went wrong.
Your processes can be identified by their names.

## Simple?
* Copy the package code to your database schema
* Call the logging procedures/functions out of your PL/SQL code
* Check log entries in the log tables

## Logging
simpleOraLogger monitors different informations about your processes.

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
  gProcessId := simpleOraLogger.new_session('my application', simpleOraLogger.logLevelWarn, 30);

  -- write a log entry whenever you want
  simpleOraLogger.info(gProcessId, 'Start');
  -- for more details...
  simpleOraLogger.debug(gProcessId, 'Function A');
  -- e.g. informations when an exception was raised
  simpleOraLogger.error(gProcessId, 'I made a fault');

  -- also you can change the status during your process runs
  simpleOraLogger.set_process_status(1, 'DONE');

  -- last but not least end the logging session
  -- opional you can set the numbers of steps to do and steps done 
  simpleOraLogger.close_session(gProcessId, 100, 99, 'DONE', 1);

end MY_DEMO_PROC;
```
### Check log entries
```sql
  -- main entries are written to the default log table LOG_PROCESS
  -- details are writte to the default detail log table LOG_PROCESS_DETAIL
  -- find out your process by its process name or look for the latest entry in the LOG_PROCESS

  -- general status of your process
  -- to shorten the output here in the text I simplified some values
  select * from LOG_PROCESS where PROCESS_NAME = 'my application';

  -- get details; the NO is the serial order of entries related to the process
  select * from LOG_PROCESS_DETAIL where process_id = 1 order by NO;
```

#### Result for table LOG_PROCESS
>| ID | PROCESS_NAME   | PROCESS_START         | PROCESS_END           | STEPS_TO_DO | STEPS_DONE | STATUS | INFO
>| -- | ---------------| --------------------- | --------------------- | ----------- | ---------- | ------ | -----
>| 1  | my application | 12.01.26 18:18:53,... | 12.01.26 18:18:53,... | 100         | 99         | 2      | ERROR

#### Result for table LOG_PROCESS_DETAIL
>| PROCESS_ID | NO | INFO           | LOG_LEVEL | SESSION_TIME    | SESSION_USER | HOST_NAME | ERR_STACK        | ERR_BACKTRACE    | ERR_CALLSTACK
>| ---------- | -- | -------------- | --------- | --------------- | ------------ | --------- | ---------------- | ---------------- | ---------------
>| 1          | 1  | Start          | INFO      | 13.01.26 10:... | SCOTT        | SERVER1   | NULL             | NULL             | NULL
>| 1          | 2  | Function A     | DEBUG     | 13.01.26 11:... | SCOTT        | SERVER1   | NULL             | NULL             | "--- PL/SQL ..." 
>| 1          | 3  | I made a fault | ERROR     | 13.01.26 12:... | SCOTT        | SERVER1   | "--- PL/SQL ..." | "--- PL/SQL ..." | "--- PL/SQL ..."

