# PowerDNS Remote Backend (Perl)

This is my take on a PowerDNS backend written in Perl.

At this stage it connects to MySQL and reads the records from any PowerDNS Generic MySQL backend compatible database. It does not support DNSSEC yet. It is meant as a replacement for the generic mysql database that you can easily script with.

Please note that this backend requires PowerDNS v4.X.

There is a logfree branch available; there is no debug logging which will give a speed boost and has less module requirements. See this page: https://github.com/sysadminblog/powerdns-remote-perl/tree/logfree

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

* Data::Dumper
* DBI (with MySQL driver)
* JSON::Any
* Log::Log4perl (with filerotate)

For Debian, you can install these using this command:
```
apt-get install libjson-any-perl liblog-dispatch-filerotate-perl liblog-log4perl-perl libdbd-mysql-perl
```