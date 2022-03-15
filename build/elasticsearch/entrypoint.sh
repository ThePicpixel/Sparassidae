#!/bin/bash

/usr/share/elasticsearch/bin/elasticsearch-certutil ca --pass "" --out /shared/cert/elastic-stack-ca.p12

/usr/share/elasticsearch/bin/elasticsearch-certutil cert --ca-pass "" --pass "" --ca /shared/cert/elastic-stack-ca.p12 --out /shared/cert/elastic-certificates.p12