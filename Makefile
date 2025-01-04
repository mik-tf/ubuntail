build:
	sudo bash ubuntail.sh install

rebuild:
	sudo ubuntail uninstall
	sudo bash ubuntail.sh install
	
delete:
	sudo ubuntail uninstall