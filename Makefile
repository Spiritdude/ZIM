NAME=ZIM
VERSION=0.0.10

all::
	@echo "make install deinstall edit backup git change push pull"

requirements::
	sudo apt -y install libxapian-dev 
	sudo cpan Search::Xapian JSON Time::HiRes # IO::Uncompress::AnyUncompress

install::
	mkdir -p ~/lib/perl5
	cp ZIM.pm ~/lib/perl5/
	cp zim ~/bin/

deinstall::
	rm -f ~lib/perl5/ZIM.pm
	rm -f ~/bin/zim

backup::
	cd ..; tar cfvz ~/Backup/${NAME}-${VERSION}.tar.gz --exclude=*.zim --exclude=*.index --exclude=*xapian ${NAME}; scp ~/Backup/${NAME}-${VERSION}.tar.gz backup:Backup;

edit::
	dee4 zim ZIM.pm Makefile README.md

git::
	#git remote add origin git@git:${NAME}
	#git remote add origin git@github.com:Spiritdude/${NAME}.git
	git remote set-url origin git@github.com:Spiritdude/${NAME}.git
        
change::
	git commit -am "..."

push::
	git push -u origin master

pull::
	git pull
