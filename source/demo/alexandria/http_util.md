# Demo with "http_util" (Alexandria plsql/sql utility library)

## About
**LILA: LILA Integrated Logging Architecture**
Logging and monitoring pl/sql applications: https://github.com/dirkgermany/LILA-Logging

This demo shows the interaction between http_util (Alexandria pl/sql Utility Library) and LILA.
Alexandria see https://github.com/mortenbra/alexandria-plsql-utils.

## This demo app
First, it calls up a valid web address and writes some log entries. Immediately afterwards, it calls up another invalid address.The results of both calls you can see in the tables lila_log and lila_log_detail.

Please have a look to the procedure body and see how few calls are needed for an exact logging.

---
## Prerequisites
To try out this example only some steps must be done before.

### Oracle ACL list
Extend ACL list as sysdba (replace placeholder USER_NAME with your user):
```sql
BEGIN
  DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE (
    host       => 'httpbin.org', 
    lower_port => 443,
    upper_port => 443,
    ace        => xs$ace_type(privilege_list => xs$name_list('http', 'connect'),
                              principal_name => 'USER_NAME', -- mostly written in uppercase!
                              principal_type => XS_ACL.PTYPE_DB)
  );
END;
/
```
### Privileges of your schema user
Grant the user certain rights (also with sysdba rights)
```sql
GRANT RESOURCE TO USER_NAME;
GRANT EXECUTE ANY PROCEDURE TO USER_NAME;
GRANT SELECT ANY TABLE TO USER_NAME;
GRANT CREATE TABLE TO USER_NAME;
GRANT CREATE SESSION TO USER_NAME;
GRANT EXECUTE ON UTL_HTTP TO USER_NAME;
```
### Create packages
Three packages are needed.
Copy pl/sql code of all package script files (.pks and .pkb) into the sql window and execute them.

#### http_util
You will find http_util.pks and http_util.pkb under https://github.com/mortenbra/alexandria-plsql-utils/tree/master/ora).

#### LILA
Find the package under https://github.com/dirkgermany/LILA-Logging/tree/main/source/package.

#### Demo
Same directory as where you found this .md-file: https://github.com/dirkgermany/LILA-Logging/tree/main/source/demo/alexandria.

---
## Try the demo and see log results
Execution of demo package
```sql
exec lila_demo_http.getBlobFromUrl;
```

See log entries. The detailed table contains the backtrace and the error stack.
```sql
-- Process overview with status:
select * from lila_log;
-- Details
select * from lila_log_detail order by process_id, no;

   
