#!/bin/bash


# input
# (l) Nodi: lista di nome + fqdn ( raspberrymz@proxy-raspberrymz,raspberryvr@proxy-raspberryvr )
# (n) Nome nodo: nome ( bananam2u1oss)
# (k) Chiave: stringa base64 ( 8BLJdGh1bD03CLNoAwOwVljJaBj7Qmc9O9q )
# (d) Directories: lista di directory to sync ( /opt/data/,/opt/data2 )


nodesString=$CSYNC2_NODES
nodeName=$CSYNC2_NAME
key=$CSYNC2_KEY
dirsString=$CSYNC2_DIRS

while getopts "l:n:k:d:" opt; do
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
    \?)
      echo "Invalid option: -$OPTARG" >&2
      ;;
  esac
done

[ -z "$nodesString" ] && echo "Nodes missing, define with -l" && exit 1
[ -z "$nodeName" ] && echo "Node name missing, define with -n" && exit 1
[ -z "$key" ] && echo "Key is missing, define with -k" && exit 1
[ -z "$dirsString" ] && echo "Dirs is missing, define with -d" && exit 1

#VOLUMES
# /etc
# /var/lib/csync2

csync2CfgFile=/etc/csync2.cfg
lsyncdCfgFile=/etc/lsyncd/lsyncd.conf.lua
keyFile=/etc/csync2.key

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

echo -e "group mycluster \n{" > $csync2CfgFile
echo    "    host $nodeName;">> $csync2CfgFile
for _host in $(echo $nodesString | tr ',' '\n') ; do
echo    "    host $_host;"   >> $csync2CfgFile
done
echo    "    key $keyFile;"  >> $csync2CfgFile
for _dir in $(echo $dirsString | tr ',' '\n') ; do
echo    "    include $_dir;" >> $csync2CfgFile
done
echo    "    exclude *~ .*;" >> $csync2CfgFile
echo    "}"                  >> $csync2CfgFile

echo "Wrote \"$csync2CfgFile\""

# create lsyncd cfg
cat << EOF > $lsyncdCfgFile
settings {
        logident        = "lsyncd",
        logfacility     = "daemon",
        logfile         = "/var/log/lsyncd.log",
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
                spawn(elist, "/usr/sbin/csync2", "-x")
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
                spawn(event, "/usr/sbin/csync2", "-x")
        end,
        prepare = function(config)
                if not config.syncid then
                        error("Missing 'syncid' parameter.", 4)
                end
                local c = "csync2.cfg"
                local f, err = io.open("/etc/" .. c, "r")
                if not f then
                        error("Invalid 'syncid' parameter: " .. err, 4)
                end
                f:close()
        end
}
local sources = {
$(for _dir in $(echo $dirsString | tr ',' '\n') ; do echo "        [\"$_dir\"] = \"node\","; done)
}
for key, value in pairs(sources) do
        sync {initSync, source=key, syncid=value}
end
EOF
echo "Wrote \"$lsyncdCfgFile\""

# write csync2 key
echo "$key" > $keyFile
echo "Wrote \"$keyFile\""

# setup /etc/hosts



