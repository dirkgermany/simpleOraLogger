# simpleOraLogger

## About
PL/SQL Package for simple logging of PL/SQL processes. Allows multiple and parallel logging out of the same session.

Even though debug information can be written, simplelogger is primarily intended for monitoring (automated) PL/SQL processes.
For easy daily monitoring log informations are written into two tables: one to see the status of your processes, one to see more details, e.g. something went wrong.
Your processes can be identified by their names.

Simple means:
* Copy the package code to your database schema
* Call the procedures/functions out of your PL/SQL code
* Check log entries in the log tables

## 
