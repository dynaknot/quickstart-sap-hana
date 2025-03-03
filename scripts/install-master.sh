#!/bin/bash
# ------------------------------------------------------------------
#
#          Install SAP HANA Master Node
#		   invoked once via cloudformation call through user-data
# ------------------------------------------------------------------

SCRIPT_DIR=/root/install/

usage() {
	cat <<EOF
	Usage: $0 [options]
		-h print usage
		-s SID
		-i instance
		-p HANA password
		-n MASTER_HOSTNAME
		-d DOMAIN
		-w WORKER_HOSTNAME
		-l HANA_LOG_FILE [optional]
EOF
	exit 1
}

[ -e /root/install/jq ] && export JQ_COMMAND=/root/install/jq
[ -z ${JQ_COMMAND} ] && export JQ_COMMAND=/home/ec2-user/jq
export PATH=${PATH}:/sbin:/usr/sbin:/usr/local/sbin:/root/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin/X11:/usr/X11R6/bin:/usr/games:/usr/lib/AmazonEC2/ec2-api-tools/bin:/usr/lib/AmazonEC2/ec2-ami-tools/bin:/usr/lib/mit/bin:/usr/lib/mit/sbin
myInstance=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document/ | ${JQ_COMMAND} '.instanceType' | \
			 sed 's/"//g')

export USE_NEW_STORAGE=1

[ -e /root/install/config.sh ] && source /root/install/config.sh
[ -e /root/install/os.sh ] && source /root/install/os.sh

# ------------------------------------------------------------------
#          Choose default log file
# ------------------------------------------------------------------

log() {
	echo $* 2>&1 | tee -a ${HANA_LOG_FILE}
}

if [ -z "${HANA_LOG_FILE}" ] ; then
    HANA_LOG_FILE=${SCRIPT_DIR}/install.log
fi

# Cleanup secret details from log files
for f in /var/log/cloud-init.log  /var/log/messages /var/log/cloud-init-output.log
do
  log "Cleaning secrets info from $f"
  sed -i '/install-master/d' $f
done

update_status () {
   local status="$1"
   if [ "$status" ]; then
      if [ -e /root/install/cluster-watch-engine.sh ]; then
         sh /root/install/cluster-watch-engine.sh -s "$status"
      fi
   fi
}

create_volume () {
	if (( ${USE_NEW_STORAGE} == 1 )); then
		log `date` "Creating Physical Volumes for SAP HANA Data and Log volume groups"
		#for i in {b..m}
		for i in {b..f}
		do
		  pvcreate /dev/xvd$i
		done
		for i in {h..i}
		do
		  pvcreate /dev/xvd$i
		done
	fi
}



set_noop_scheduler () {
	
	if [[ $(grep -wq noop /sys/block/*/queue/scheduler; echo $?) -eq 0 ]]; then
		for i in `pvs | grep dev | awk '{print $1}' | sed s/\\\/dev\\\///`
		do
			log `date` "Setting i/o scheduler to noop for each physical volume"
			echo "noop" > /sys/block/$i/queue/scheduler
			printf "$i: "
			cat /sys/block/$i/queue/scheduler
		done
		sed -i.bkup 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& elevator=noop /' /etc/default/grub
		grub2-mkconfig -o /boot/grub2/grub.cfg >> ${HANA_LOG_FILE} 2>&1
	else
		for i in `pvs | grep dev | awk '{print $1}' | sed s/\\\/dev\\\///`
		do
	    	log `date` "Setting i/o scheduler to none for each physical volume"
	    	echo "none" > /sys/block/$i/queue/scheduler
	    	log `date` "$i: "
	    	log `date` `cat /sys/block/$i/queue/scheduler`
	    done
	    sed -i.bkup 's/GRUB_CMDLINE_LINUX_DEFAULT="[^"]*/& elevator=none /' /etc/default/grub
	    grub2-mkconfig -o /boot/grub2/grub.cfg >> ${HANA_LOG_FILE} 2>&1
	fi

	if [[ "$MyOS" =~ 12 ]]; then
		# SLES12 doesn't honor "elevator" kernel param on blk_mq schedulers
		cat <<_EOF >> /etc/init.d/boot.local
for i in \$(pvs | grep dev | awk '{print \$1}' | sed s/\\\/dev\\\///)
do
   echo "none" > /sys/block/\$i/queue/scheduler
done
_EOF
    elif [[ "$MyOS" =~ 15 ]]; then
       #  SLES15 doesn't honor "elevator" kernel param on blk_mq schedulers
		cat <<_EOF >> /etc/init.d/after.local
#!/bin/bash
for i in \$(ls /sys/block/)
do
   echo "none" > /sys/block/\$i/queue/scheduler
done
_EOF
		chmod +x /etc/init.d/after.local
		systemctl enable --now after-local
	fi
	
}


# ------------------------------------------------------------------
#          Read all inputs
# ------------------------------------------------------------------

while getopts ":h:s:i:p:n:d:w:l:" o; do
    case "${o}" in
    h) usage && exit 0
			;;
		s) SID=${OPTARG}
			;;
		i) INSTANCE=${OPTARG}
			;;
		p) HANAPASSWORD=${OPTARG}
			;;
		n) MASTER_HOSTNAME=${OPTARG}
			;;
		d) DOMAIN=${OPTARG}
			;;
    w) WORKER_HOSTNAME=${OPTARG}
      ;;
    l) HANA_LOG_FILE=${OPTARG}
      ;;
    *)
       usage
      ;;
    esac
done


if (( $(isSLES12) == 1 )); then
	if [ -d "/home/ec2-user/media.cache" ]; then
		export ENABLE_FAST_DEBUG=1
	else
		export ENABLE_FAST_DEBUG=0
	fi
else
	export ENABLE_FAST_DEBUG=0
fi


# ------------------------------------------------------------------
#          Build storage from storage.json
#		   First build a master script via generator code, then run it
# ------------------------------------------------------------------


MyInstanceType=$(/usr/local/bin/aws cloudformation describe-stacks --stack-name ${MyStackId}  --region ${REGION}  \
				| /root/install/jq '.Stacks[0].Parameters[] | select(.ParameterKey=="MyInstanceType") | .ParameterValue' \
				| sed 's/"//g')

MyHanaDataVolumeType=$(/usr/local/bin/aws cloudformation describe-stacks --stack-name ${MyStackId}  --region ${REGION}  \
				| /root/install/jq '.Stacks[0].Parameters[] | select(.ParameterKey=="VolumeTypeHanaData") | .ParameterValue' \
				| sed 's/"//g')

MyHanaLogVolumeType=$(/usr/local/bin/aws cloudformation describe-stacks --stack-name ${MyStackId}  --region ${REGION}  \
				| /root/install/jq '.Stacks[0].Parameters[] | select(.ParameterKey=="VolumeTypeHanaLog") | .ParameterValue' \
				| sed 's/"//g')

if [ -f /root/install/storage.json ] && [ -s /root/install/storage.json ] ; then
	 	log `date` "storage.json file is available, proceeding with volume creation"
else
	 	#Exiting since storage.json file size is 0. Probably due to custom storage.json
	 	log `date` "Exiting script since storage.json file is either empty or not available"
	 	log `date` "Check if custom storage.json file has correct permission and retry again"
	 	log `date` "Calling signal-failure.sh with EMPTY_STORAGE_JSON parameter"
	 	/root/install/signal-failure.sh "EMPTY_STORAGE_JSON"
	 	touch "$SIG_FLAG_FILE"
	 	sleep 300
	 	exit 1
fi

#log `date` "Building storage script to provision and configure EBS volumes for SAP HANA"
STORAGE_SCRIPT=/root/install/storage_builder_generated_master.sh
if [ ${AWSEFS} == 'No' ] || [ ${HostCount} -eq 1 ]
then
    log `date` "Provisioning and configuring EBS Volumes for HANA Backup"
    ${PYTHON_BIN} /root/install/build_storage.py  -config /root/install/storage.json  \
	    				     -ismaster ${IsMasterNode} \
		    			     -hostcount ${HostCount} -which backup \
			    		     -instance_type ${MyInstanceType} -storage_type ${BACKUP_VOL} \
				    	     > ${STORAGE_SCRIPT}
    log `date` "Provisioning and configuring EBS Volumes for HANA Shared"
    ${PYTHON_BIN} /root/install/build_storage.py  -config /root/install/storage.json  \
	    				     -ismaster ${IsMasterNode} \
		    			     -hostcount ${HostCount} -which shared \
			    		     -instance_type ${MyInstanceType} -storage_type ${SHARED_VOL} \
				    	     >> ${STORAGE_SCRIPT}
fi
log `date` "Provisioning and configuring EBS Volumes for HANA Data"
${PYTHON_BIN} /root/install/build_storage.py  -config /root/install/storage.json  \
							 -ismaster ${IsMasterNode} \
							 -hostcount ${HostCount} -which hana_data \
							 -instance_type ${MyInstanceType} -storage_type ${MyHanaDataVolumeType} \
							 >> ${STORAGE_SCRIPT}
log `date` "Provisioning and configuring EBS Volumes for HANA Log"
${PYTHON_BIN} /root/install/build_storage.py  -config /root/install/storage.json  \
							 -ismaster ${IsMasterNode} \
							 -hostcount ${HostCount} -which hana_log \
							 -instance_type ${MyInstanceType} -storage_type ${MyHanaLogVolumeType} \
							 >> ${STORAGE_SCRIPT}
log `date` "Provisioning and configuring EBS Volumes for USR-SAP"
${PYTHON_BIN} /root/install/build_storage.py  -config /root/install/storage.json  \
	       				     -ismaster ${IsMasterNode} \
		    			     -hostcount ${HostCount} -which usr_sap \
			    		     -instance_type ${MyInstanceType} -storage_type ${USR_SAP_VOL} \
				    	     >> ${STORAGE_SCRIPT}
log `date` "Provisioning and configuring EBS Volumes for HANA Media"
${PYTHON_BIN} /root/install/build_storage.py  -config /root/install/storage.json  \
							 -ismaster ${IsMasterNode} \
							 -hostcount ${HostCount} -which media \
							 -instance_type ${MyInstanceType} -storage_type ${HANA_MEDIA_VOL} \
							 >> ${STORAGE_SCRIPT}


# ------------------------------------------------------------------
#          Helper functions
#          log()
#          update_status()
#          create_volume()
#          set_noop_scheduler()
# ------------------------------------------------------------------

#Check if SIG_FLAG_FILE is present

if [ $(issignal_check) == 1 ]; then
    #Exit since there is a signal file
    log `date` "Exiting $0 script at `date` because $SIG_FLAG_FILE exists"
    exit 1
fi


# ------------------------------------------------------------------
#          Make sure all input parameters are filled
# ------------------------------------------------------------------


[[ -z "$SID" ]]  && echo "input SID missing" && usage;
[[ -z "$INSTANCE" ]]  && echo "input INSTANCE missing" && usage;
[[ -z "$HANAPASSWORD" ]]  && echo "input HANAPASSWORD missing" && usage;
[[ -z "$MASTER_HOSTNAME" ]]  && echo "input MASTER_HOSTNAME missing" && usage;

shift $((OPTIND-1))

[[ $# -gt 0 ]] && usage;


#if (( ${USE_NEW_STORAGE} == 1 ));
#then
#	log `date` "Using New Storage from storage.json"
#	sh -x ${STORAGE_SCRIPT} >> ${HANA_LOG_FILE}
#	log `date` "END Storage from storage.json"
#fi

echo `date` BEGIN install-master  2>&1 | tee -a ${HANA_LOG_FILE}

update_status "CONFIGURING_INSTANCE_FOR_HANA"
#create_volume;
set_noop_scheduler;


# logsize=",c3.8xlarge:244G,r3.2xlarge:244G,r3.4xlarge:244G,r3.8xlarge:244G,"
# datasize=",c3.8xlarge:488G,r3.2xlarge:488G,r3.4xlarge:488G,r3.8xlarge:488G,"
# sharedsize=",c3.8xlarge:244G,r3.2xlarge:244G,r3.4xlarge:244G,r3.8xlarge:244G,"
# backupsize=",1:488G,2:976G,3:1464G,4:1952G,5:2440G,6:2928G,7:3416G,8:3904G,9:4392G,10:4880G,11:5368G,12:5856G,13:6344G,14:6832G,15:7320G,16:7808G,17:8296G,18:8784G,19:9272G,20:9760G,"


# get_logsize() {
#     echo "$(expr "$logsize" : ".*,$1:\([^,]*\),.*")"
# }

# get_datasize() {
#     echo "$(expr "$datasize" : ".*,$1:\([^,]*\),.*")"
# }
# get_sharedsize() {
#     echo "$(expr "$sharedsize" : ".*,$1:\([^,]*\),.*")"
# }

# get_backupsize() {
#     echo "$(expr "$backupsize" : ".*,$1:\([^,]*\),.*")"
# }

# mylogSize=$(get_logsize  ${myInstance})
# mydataSize=$(get_datasize   ${myInstance})
# mysharedSize=$(get_sharedsize  ${myInstance})
# mybackupSize=$(get_backupsize  ${HostCount})

# ------------------------------------------------------------------
#          Create volume group vghana
#          Create Logical Volumes
#          Format filesystems
# ------------------------------------------------------------------

# if (( ${USE_NEW_STORAGE} == 1 ));
# then
#
# #	log `date` "Formatting block device for /usr/sap"
# #	mkfs.xfs -f /dev/xvds
#
# 	## 9.1 Create a new volume to store media.
# 	## This is where media bits will be downloaded from S3 and extracted
# 	log `date` "Creating volume for HANA Media /media"
# 	sh -x /root/install/create-attach-single-volume.sh 50:gp2:/dev/sdz:HANA-MEDIA
# 	mkfs.xfs -f /dev/xvdz
# 	mkdir -p /media/
# 	mount /dev/xvdz /media/
#
# else
# 	log `date` "Creating volume group vghana"
# 	#vgcreate vghana /dev/xvd{b..m}
# 	vgcreate vghana /dev/xvd{b..d}
#
# 	###7. Created a new volume group called vghanaback  (Master only)
# 	vgcreate vghanaback /dev/xvd{e..f}
#
#
# 	###8. Updated number of stripes to 3 for logical volumes created under volume group vghana (Both Master and Worker)
#
# 	lvcreate -n lvhanashared -i 3 -I 256 -L ${mysharedSize}  vghana
# 	log `date` "Creating hana data logical volume"
# 	lvcreate -n lvhanadata -i 3 -I 256  -L ${mydataSize} vghana
# 	log `date` "Creating hana log logical volume"
# 	lvcreate -n lvhanalog  -i 3 -I 256 -L ${mylogSize} vghana
#
#
# 	##9.Created a new logical volume called lvhanaback with 2 stripes (Master Only)
# 	log `date` "Creating backup logical volume"
# 	lvcreate -n lvhanaback  -i 2 -I 256  -L ${mybackupSize} vghanaback
#
# 	log `date` "Formatting block device for /usr/sap"
# 	mkfs.xfs -f /dev/xvds
#
# 	## 9.1 Create a new volume to store media.
# 	## This is where media bits will be downloaded from S3 and extracted
# 	mkfs.xfs -f /dev/xvdz
# 	mkdir -p /media/
# 	mount /dev/xvdz /media/
# fi


#/backup /hana/shared /hana/log /hana/data

for lv in `ls /dev/mapper | grep vghana`
do
   log `date` "Formatting logical volume $lv"
   mkfs.xfs /dev/mapper/$lv
done


# ------------------------------------------------------------------
#       Nov 28, 2018
#		Create swap file /SWAPS/swap2G, 2G in size
#		Update /etc/fstab
# ------------------------------------------------------------------
log `date` "Creating 2G swap space /SWAPS/swap2G"
mkdir /SWAPS
sf=/SWAPS/swap2G
dd if=/dev/zero of=${sf} bs=1G count=2
chmod 600 ${sf}
mkswap ${sf}
swapon ${sf}
echo "${sf}	swap swap defaults 0 0" >> /etc/fstab
log `date` `swapon --show`
log `date` "End of creating swap space"


# ------------------------------------------------------------------
#          Create mount points and important directories
#		   Update /etc/fstab
#		   Mount all filesystems
# ------------------------------------------------------------------

log `date` "Creating SAP and HANA directories"
mkdir -p /usr/sap
mkdir -p /media

mkdir -p /hana /hana/log /hana/data /hana/shared
mkdir -p /backup

#log `date` "Creating SAP and HANA shared dir"
#mkdir -p /shared
#if (( ${USE_NEW_STORAGE} == 1 ));then
#	mkfs.xfs -f /dev/xvde
#	mount /dev/xvde /hana/shared/
#fi

log `date` "Creating mount points in fstab"

MntOpt=""
if  ( [ "$MyOS" = "SLES11SP4HVM" ] || [ "$MyOS" = "RHEL66SAPHVM" ] || [ "$MyOS" = "RHEL67SAPHVM" ] );
then
    MntOpt=",delaylog"
fi
echo "/dev/disk/by-label/USR_SAP /usr/sap   xfs noatime,nodiratime,logbsize=256k${MntOpt} 0 0" >> /etc/fstab
echo "/dev/disk/by-label/HANA_MEDIA /media   xfs noatime,nodiratime,logbsize=256k${MntOpt} 0 0"  >> /etc/fstab
echo "/dev/mapper/vghanadata-lvhanadata     /hana/data     xfs noatime,nodiratime,logbsize=256k${MntOpt} 0 0" >> /etc/fstab
echo "/dev/mapper/vghanalog-lvhanalog      /hana/log      xfs noatime,nodiratime,logbsize=256k${MntOpt} 0 0" >> /etc/fstab
if [ ${AWSEFS} == 'Yes' ] && [ ${HostCount} -gt 1 ]
then
    log `date` "Provisioning and configuring Amazon EFS for HANA Shared and Backup"
    EFS_MP_shared="${EFSshared}.efs.${REGION}.amazonaws.com:/ "
    EFS_MP_backup="${EFSbackup}.efs.${REGION}.amazonaws.com:/ "
    echo ""$EFS_MP_shared"  "/hana/shared"  nfs nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0"  >> /etc/fstab
    echo ""$EFS_MP_backup"  "/backup"  nfs nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0"  >> /etc/fstab
else
    echo "/dev/disk/by-label/HANA_SHARE /hana/shared   xfs noatime,nodiratime,logbsize=256k${MntOpt} 0 0" >> /etc/fstab
    echo "/dev/mapper/vghanaback-lvhanaback     /backup        xfs noatime,nodiratime,logbsize=256k${MntOpt} 0 0" >> /etc/fstab
fi

##10. Updated the fstab entry for /backup (Master only)

log `date` "Mounting filesystems"
mount -a
mount

# ------------------------------------------------------------------
if (( ${ENABLE_FAST_DEBUG} == 1 ));
then
	log `date` "WARNING !!!!!! FAST DEBUG ENABLED. NEED TO DISABLE THIS!"
	log `date` "BYPASSING S3 MEDIA DOWNLOAD"
	mkdir -p /media
	cp -r /home/ec2-user/media.cache /media
else
	log `date` "Downloading SAP HANA Media from S3: START"
	
	# Download media
	${PYTHON_BIN} ${SCRIPT_DIR}/download_media.py  -o /media/
	log `date` "Downloading SAP HANA Media from S3: END"
	
	# Check if SAP HANA media satisfies SAP HANA Fast Restart needs
	log `date` "Checking media label for SAP HANA version"
	if [[ "${FastRestartEnabled}" == "Yes" ]]; then
		#
		HANA_V=$(sh ${SCRIPT_DIR}/check-hana-version.sh -v)  # HANA version
		HANA_SPS=$(sh ${SCRIPT_DIR}/check-hana-version.sh -s | tr -d 'SPS') # HANA SPS
		#
		if [ ${HANA_V} == "2.0" -a ${HANA_SPS} -ge 4 ]; then
			# Good for SAP HANA FR
			cp ${SCRIPT_DIR}/sap-hana-tmpfs.service /etc/systemd/system/
			cp ${SCRIPT_DIR}/sap-hana-tmpfs.sh /etc/rc.d/
			sed -i -e "s/HDB/${SID}/" /etc/rc.d/sap-hana-tmpfs.sh
			systemctl daemon-reload
			systemctl enable --now sap-hana-tmpfs
			mount | grep -q '/hana/tmpfs' || \
				( log "`date` ERROR: Unable to mount tmpfs - aborting" ; \
				sh ${SCRIPT_DIR}/signal-failure.sh "TMPFSFAIL" )
		else
			sh ${SCRIPT_DIR}/signal-failure.sh "HANACHECKFAIL"
		fi
	fi
	
	# extract media
	log `date` "Extracting SAP HANA Media: START"
	sh ${SCRIPT_DIR}/extract.sh
	log `date` "Extracting SAP HANA Media: END"
fi

# ------------------------------------------------------------------
#          Creating additional directories
#          Activate LVM @boot
# ------------------------------------------------------------------

mkdir -p /hana/data/$SID /hana/log/$SID
mkdir -p  /usr/sap/$SID
mkdir -p /backup/data /backup/log /backup/data/$SID /backup/log/$SID

if (( $(isSLES) == 1 )); then
	log `date` "Turning on Activate of LVM at boot"
	chkconfig boot.lvm on
fi

# ------------------------------------------------------------------
#         Configure NFS exports
# ------------------------------------------------------------------
##ensure nfs service starts on boot
if (( $(isSLES) == 1 )); then
    log `date` "Installing and configuring NFS Server"
    zypper --non-interactive install nfs-kernel-server
fi

if (( $(isSLES) == 1 )); then
    sed -i '/STATD_PORT=/ c\STATD_PORT="4000"' /etc/sysconfig/nfs
    sed -i '/LOCKD_TCPPORT=/ c\LOCKD_TCPPORT="4001"' /etc/sysconfig/nfs
    sed -i '/LOCKD_UDPPORT=/ c\LOCKD_UDPPORT="4001"' /etc/sysconfig/nfs
    sed -i '/MOUNTD_PORT=/ c\MOUNTD_PORT="4002"' /etc/sysconfig/nfs
    service nfsserver start
    chkconfig nfsserver on
elif (( $(isRHEL8) == 1 )); then
    systemctl enable nfs-server
    systemctl start nfs-server
elif (( $(isRHEL) == 1 )); then
    sed -i '/STATD_PORT=/ c\STATD_PORT="4000"' /etc/sysconfig/nfs
    sed -i '/LOCKD_TCPPORT=/ c\LOCKD_TCPPORT="4001"' /etc/sysconfig/nfs
    sed -i '/LOCKD_UDPPORT=/ c\LOCKD_UDPPORT="4001"' /etc/sysconfig/nfs
    sed -i '/MOUNTD_PORT=/ c\MOUNTD_PORT="4002"' /etc/sysconfig/nfs
    service nfs restart
    chkconfig nfs on
fi

if [ ${AWSEFS} == 'No' ]
then
    echo "#Share global HANA shares" >> /etc/exports
    if (( ${USE_NEW_STORAGE} == 1 )); then
        echo "/hana/shared   ${WORKER_HOSTNAME}*(rw,no_root_squash,no_subtree_check)" >> /etc/exports
    else
        echo "/hana/shared   ${WORKER_HOSTNAME}*(rw,no_root_squash,no_subtree_check)" >> /etc/exports
    fi
    echo "/backup        ${WORKER_HOSTNAME}*(rw,no_root_squash,no_subtree_check)" >> /etc/exports
    exportfs -a

    log `date` "Current exports"
    showmount -e
fi

# ------------------------------------------------------------------
#          Pass through HANA installation
# ------------------------------------------------------------------

if [ "${INSTALL_HANA}" == "No" ]; then
    log `date` "INSTALL_HANA set to No, will pass through install-master.sh"
    exit 0
else
    log `date` "INSTALL_HANA set to Yes, Will install HANA via install-master.sh"
fi


# ------------------------------------------------------------------
#          Install HANA Master
# ------------------------------------------------------------------
update_status "INSTALLING_SAP_HANA"
sh ${SCRIPT_DIR}/install-hana-master.sh -p $HANAPASSWORD -s $SID -i $INSTANCE -n $MASTER_HOSTNAME -d $DOMAIN
update_status "PERFORMING_POST_INSTALL_STEPS"

#--------------------------------------------------------------------------------
#          Update Init scripts to make autofs start before SAP upon system reboot
#--------------------------------------------------------------------------------

if (( $(isSLES) == 1 )); then
	sed -i '/# Required-Start:/ c\# Required-Start: $network $syslog $remote_fs $time autofs' /etc/init.d/sapinit
	insserv sapinit
	chkconfig sapinit on
else
	sed -i '/# Required-Start:/ c\# Required-Start: $network $syslog $remote_fs $time autofs' /etc/init.d/sapinit
	chkconfig sapinit on
fi

log `date` END install-master

cat ${HANA_LOG_FILE} >> /var/log/messages

# Post installation: Install AWS Data provider

if [[ "${MyOS}" == "SLES"* ]]; then
	# Install SAP Data Provider for SLES
	cd /root/install/
	wget https://aws-sap-data-provider.s3.amazonaws.com/Installers/aws-sap-dataprovider-sles-standalone.x86_64.rpm
	wget https://aws-sap-data-provider.s3.amazonaws.com/Installers/RPM-GPG-KEY-AWS
	rpm --import RPM-GPG-KEY-AWS
	zypper install -y aws-sap-dataprovider-sles-standalone.x86_64.rpm
else
	# Install SAP Data Provider for RHEL
	wget https://aws-sap-data-provider.s3.amazonaws.com/Installers/aws-sap-dataprovider-rhel-standalone.x86_64.rpm
	yum -y install aws-sap-dataprovider-rhel-standalone.x86_64.rpm
fi

exit 0
