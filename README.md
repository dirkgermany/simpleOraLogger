# simpleOraLogger

## About
PL/SQL Package for simple logging of PL/SQL processes. Allows multiple and parallel logging out of the same session.

Even though debug information can be written, simpleOraLogger is primarily intended for monitoring (automated) PL/SQL processes (hereinafter referred to as the processes).
For easy daily monitoring log informations are written into two tables: one to see the status of your processes, one to see more details, e.g. something went wrong.
Your processes can be identified by their names.

## Simple means:
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
   ```sql
   -- global process ID related to your log process
   gProcessId number(19,0);

   -- begin a new logging session
   gProcessId := pck_logging.new_session('my application', simpleOraLogger.logLevelWarn, 30);
   pck_logging.info(gProcessId, 'Something happened or not');

   ```sql
