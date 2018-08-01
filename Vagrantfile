# -*- mode: ruby -*-
# vi: set ft=ruby :

# All Vagrant configuration is done below. The "2" in Vagrant.configure
# configures the configuration version (we support older styles for
# backwards compatibility). Please don't change it unless you know what
# you're doing.
Vagrant.configure("2") do |config|
  config.vm.provider "virtualbox" do |v|
    v.customize ["modifyvm", :id, "--memory", "4096", "--ioapic", "on", "--cpus", "4"]
  end

  config.vm.synced_folder ".", "/vagrant"

  config.vm.define "controller", autostart: false do |ubuntu|
    ubuntu.vm.box = 'ubuntu/xenial64'
    ubuntu.vm.provision :shell, inline: <<-SHELL
      [ -f /vagrant/controller/install/ubuntu.sh ] && cp /vagrant/controller/install/ubuntu.sh /usr/bin/controller-install && chmod 755 /usr/bin/controller-install
      [ -f /vagrant/controller/update/ubuntu.sh ] && cp /vagrant/controller/update/ubuntu.sh /usr/bin/controller-update && chmod 755 /usr/bin/controller-update
      [ -f /vagrant/controller/upgrade/ubuntu.sh ] && cp /vagrant/controller/upgrade/ubuntu.sh /usr/bin/controller-upgrade && chmod 755 /usr/bin/controller-upgrade
    SHELL
  end

  config.vm.define "host", autostart: false do |ubuntu|
    ubuntu.vm.box = 'ubuntu/xenial64'
    # ubuntu.vm.provision :shell, inline: ""
  end

  config.vm.define "provider", autostart: false do |ubuntu|
    ubuntu.vm.box = 'ubuntu/xenial64'
    # ubuntu.vm.provision :shell, inline: ""
  end

  config.vm.define "vpn", autostart: false do |ubuntu|
    ubuntu.vm.box = 'ubuntu/xenial64'
    ubuntu.vm.provision :shell, inline: <<-SHELL
      [ -f /vagrant/vpn/install/ubuntu.sh ] && cp /vagrant/vpn/install/ubuntu.sh /usr/bin/vpn-install && chmod 755 /usr/bin/vpn-install
      [ -f /vagrant/vpn/update/ubuntu.sh ] && cp /vagrant/vpn/update/ubuntu.sh /usr/bin/vpn-update && chmod 755 /usr/bin/vpn-update
      [ -f /vagrant/vpn/upgrade/ubuntu.sh ] && cp /vagrant/vpn/upgrade/ubuntu.sh /usr/bin/vpn-upgrade && chmod 755 /usr/bin/vpn-upgrade
    SHELL
  end
end
