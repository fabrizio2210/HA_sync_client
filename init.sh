#!/bin/bash


# input
# (l) Nodi: lista di nome + fqdn ( raspberrymz@proxy-raspberrymz,raspberryvr@proxy-raspberryvr ) (tutti i nodi)
# (n) Nome nodo: nome ( bananam2u1oss)
# (k) Chiave: stringa base64 ( 8BLJdGh1bD03CLNoAwOwVljJaBj7Qmc9O9q )
# (d) Directories: lista di directory to sync ( /opt/data/,/opt/data2 )
# (a) authJson: json per impostare autenticazione al proxy


nodesString=$CSYNC2_NODES
nodeName=$CSYNC2_NAME
key=$CSYNC2_KEY
dirsString=$CSYNC2_DIRS
authJson=$CSYNC2_AUTHJSON

while getopts "l:n:k:d:a:" opt; do
  case $opt in
    l)
      nodesString=$(echo $OPTARG | tr -d '[[:space:]]')
      ;;
		n)
			nodeName=$(echo $OPTARG | tr -d '[[:space:]]')
			;;
		k)
			key=$(echo $OPTARG | tr -d '[[:space:]]')
			;;
		d)
			dirsString=$(echo $OPTARG | tr -d '[[:space:]]')
      ;;
		a)
			authJson=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      ;;
  esac
done

[ -z "$nodesString" ] && echo "Nodes missing, define with -l" && exit 1
[ -z "$nodeName" ] && echo "Node name missing, define with -n" && exit 1
[ -z "$key" ] && echo "Key is missing, define with -k" && exit 1
[ -z "$dirsString" ] && echo "Dirs is missing, define with -d" && exit 1
[ -z "$authJson" ] && echo "Auth json is missing, define with -a" && exit 1

#VOLUMES
# /etc
# /var/lib/csync2

csync2CfgDir=/etc/
lsyncdCfgFile=/etc/lsyncd/lsyncd.conf.lua
keyFile=/etc/csync2.key
confName=$(echo $nodeName | tr -d '._-')
authFile=/etc/chisel.auth
echo "configuration name: $confName"

######
# MAIN

###
# create certificate
if [ ! -e /etc/csync2_ssl_cert.pem ] ; then
        openssl genrsa -out /etc/csync2_ssl_key.pem 1024
        ls -l /etc/csync2_ssl_key.pem
        openssl req -batch -new -key /etc/csync2_ssl_key.pem -out /etc/csync2_ssl_cert.csr
        ls -l /etc/csync2_ssl_cert.csr
        openssl x509 -req -days 3600 -in /etc/csync2_ssl_cert.csr -signkey /etc/csync2_ssl_key.pem -out /etc/csync2_ssl_cert.pem
        ls -l /etc/csync2_ssl_cert.pem
        echo "Wrote \"/etc/csync2_ssl_cert.pem\""
fi

###
# create csync2 cfg
mkdir -p $csync2CfgDir
for _hostString in $(echo $nodesString | tr ',' '\n') ; do
        __host=${_hostString%%@*}
        csync2CfgFile="$csync2CfgDir/csync2_$(echo ${__host} | tr -d '._-').cfg"
        echo -e "group mycluster \n{" > $csync2CfgFile
        for _host in $(echo $nodesString | tr ',' '\n') ; do
                if [  "${_host%%@*}" != "$__host" ] ; then
                        # host slave
                        echo    "    host ($_host);"   >> $csync2CfgFile
                else
                        # host master
                        echo    "    host ${_host%%@*};"   >> $csync2CfgFile
                fi
        done
        echo    "    key $keyFile;"  >> $csync2CfgFile
        for _dir in $(echo $dirsString | tr ',' '\n') ; do
                echo    "    include $_dir;" >> $csync2CfgFile
        done
        echo    "    exclude *~ .*;" >> $csync2CfgFile
        echo    "}"                  >> $csync2CfgFile

        echo "Wrote \"$csync2CfgFile\""
done

mkdir -p $(dirname $lsyncdCfgFile)
# create lsyncd cfg
cat << EOF > $lsyncdCfgFile
settings {
        logident        = "lsyncd",
        logfacility     = "daemon",
        logfile         = "/dev/null",
        statusFile      = "/var/log/lsyncd_status.log",
        statusInterval  = 1
}
initSync = {
        delay = 1,
        maxProcesses = 1,
        exitcodes = {[1] = 'again'},
        action = function(inlet)
                local config = inlet.getConfig()
                local elist = inlet.getEvents(function(event)
                        return event.etype ~= "Init"
                end)
                local directory = string.sub(config.source, 1, -2)
                local paths = elist.getPaths(function(etype, path)
                        return "\t" .. config.syncid .. ":" .. directory .. path
                end)
                log("Normal", "Processing syncing list:\n", table.concat(paths, "\n"))
                spawn(elist, "/usr/sbin/csync2", "-x", "-C", config.syncid, "-N", "$nodeName")
        end,
        collect = function(agent, exitcode)
                local config = agent.config
                if not agent.isList and agent.etype == "Init" then
                        if exitcode == 0 then
                                log("Normal", "Startup of '", config.syncid, "' instance finished.")
                        elseif config.exitcodes and config.exitcodes[exitcode] == "again" then
                                log("Normal", "Retrying startup of '", config.syncid, "' instance. RC=" .. exitcode)
                                return "again"
                        else
                                log("Error", "Failure on startup of '", config.syncid, "' instance. RC=" .. exitcode)
                                terminate(-1)
                        end
                        return
                end
                local rc = config.exitcodes and config.exitcodes[exitcode]
                if rc == "die" then
                        return rc
                end
                if agent.isList then
                        if rc == "again" then
                                log("Normal", "Retrying events list on exitcode = ", exitcode)
                        else
                                log("Normal", "Finished events list = ", exitcode)
                        end
                else
                        if rc == "again" then
                                log("Normal", "Retrying ", agent.etype, " on ", agent.sourcePath, " = ", exitcode)
                        else
                                log("Normal", "Finished ", agent.etype, " on ", agent.sourcePath, " = ", exitcode)
                        end
                end
                return rc
        end,
        init = function(event)
                local inlet = event.inlet;
                local config = inlet.getConfig();
                log("Normal", "Recursive startup sync: ", config.syncid, ":", config.source)
                spawn(event, "/usr/sbin/csync2", "-C", config.syncid, "-xr", "-N", "$nodeName")
        end,
        prepare = function(config)
                if not config.syncid then
                        error("Missing 'syncid' parameter.", 4)
                end
                local c = "csync2_" .. config.syncid .. ".cfg"
                local f, err = io.open("/etc/" .. c, "r")
                if not f then
                        error("Invalid 'syncid' parameter: " .. err, 4)
                end
                f:close()
        end
}
local sources = {
$(for _dir in $(echo $dirsString | tr ',' '\n') ; do echo "        [\"$_dir\"] = \"$confName\","; done)
}
for key, value in pairs(sources) do
        sync {initSync, source=key, syncid=value}
end
EOF
for _dir in $(echo $dirsString | tr ',' '\n') ; do
  mkdir -p $_dir
done

echo "Wrote \"$lsyncdCfgFile\""

###
# write csync2 key
echo "$key" > $keyFile
echo "Wrote \"$keyFile\""

###
# write auth file for proxy
echo "$authJson" > $authFile
echo "Wrote \"$authFile\""

###
# setup /etc/hosts

for _hostString in $(echo $nodesString | tr ',' '\n') ; do
  _host=${_hostString%%@*}
  sed -i "/.*$_host.*/d" /etc/hosts
  _string="127.0.0.1  $_host" 
  if ! grep -q "$_string"  /etc/hosts ; then
    echo "Insert $_string in /etc/hosts"
    echo $_string >> /etc/hosts
  fi
done
echo "Wrote /etc/hosts"


###
# Run csync2

stdbuf -oL csync2 -ii -v -N $nodeName -C $confName | sed -u -e 's/^/csync2: /' > /dev/stdout 2>&1 &
csync2Pid=$!
echo $csync2Pid > /var/run/csync2.pid

echo "Started csync2 with pid $csync2Pid"


###
# run lsyncd

stdbuf -oL /usr/bin/lsyncd  -nodaemon -delay 5 $lsyncdCfgFile 2>&1 | sed -u -e 's/^/lsyncd: /' > /dev/stdout 2>&1 &
lsyncdPid=$!
echo $lsyncdPid > /var/run/lsyncd.pid

echo "Started lsyncd with pid $lsyncdPid"


###
# Run proxy server

stdbuf -oL /usr/local/bin/chisel_linux_arm server --port 80 --proxy http://example.com --authfile $authFile 2>&1 | sed -u -e 's/^/tunnel: /' > /dev/stdout 2>&1 &
proxyPid=$!
echo $proxyPid > /var/run/proxy.pid

echo "Started proxy server with pid $proxyPid"
