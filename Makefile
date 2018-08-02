MD5SUM=$(shell { command -v md5sum || command -v md5; } 2>/dev/null)

.PHONY: all controller host provider vpn clean

all: controller host provider vpn

%.md5: %.sh
	cat $< | ${MD5SUM} | awk '{print $$1}' > $@

controller: controller/install/ubuntu.md5 controller/update/ubuntu.md5 controller/upgrade/ubuntu.md5
	for i in install update upgrade; do \
	  for j in ubuntu; do \
	    aws s3 cp --acl public-read controller/$$i/$$j.sh s3://unity.nanobox.io/bootstrap/controller/$$j/$$i; \
	    aws s3 cp --acl public-read controller/$$i/$$j.md5 s3://unity.nanobox.io/bootstrap/controller/$$j/$$i.md5; \
	  done; \
	done

host:

provider:

vpn: vpn/install/ubuntu.md5 vpn/update/ubuntu.md5 vpn/upgrade/ubuntu.md5
	for i in install update upgrade; do \
	  for j in ubuntu; do \
	    aws s3 cp --acl public-read vpn/$$i/$$j.sh s3://unity.nanobox.io/bootstrap/vpn/$$j/$$i; \
	    aws s3 cp --acl public-read vpn/$$i/$$j.md5 s3://unity.nanobox.io/bootstrap/vpn/$$j/$$i.md5; \
	  done; \
	done
