# PowerDNS Remote Backend (Perl)

This is my take on a PowerDNS backend written in Perl. This branch does not include any logging, so it will give a slight performance boost.

At this stage it connects to MySQL and reads the records from any PowerDNS Generic MySQL backend compatible database. It does not support DNSSEC yet. It is meant as a replacement for the generic mysql database that you can easily script with.

Please note that this backend requires PowerDNS v4.X.

## Usage instructions

In the pdns.conf, set the launch line to include the "remote" backend. As an example:

```
launch=remote
```

You will then need to provide a connection string to the backend. The values for MYSQL_DB, MYSQL_USER and MYSQL_PASS need to be changed to match your environment.
```
remote-connection-string=pipe:command=/path/to/remote-backend.pl,timeout=2000,dsn=DBI:mysql:MYSQL_DB,username=MYSQL_USER,password=MYSQL_PASS
```

## Required Perl Modules

The following perl modules are required:

* DBI (with MySQL driver)
* JSON::Any

For Debian, you can install these using this command:
```
apt-get install libjson-any-perl libdbd-mysql-perl
```