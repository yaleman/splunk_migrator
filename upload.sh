#!/bin/bash
# s3 upload stuff sourced from http://tmont.com/blargh/2014/1/uploading-to-s3-in-bash

if [ "$1" == "-h" ]; then
    echo "Environment variables to configure this:"
    echo "MAXTIME       =   Will automatically quit after this many seconds"
    echo "AWS_PROFILE   =   AWS profile to use"
    echo "AWS_REGION    =   AWS region the bucket is in (Region is optional, if you don't set it, I'll try and get it from ~/.aws/credentials)"
    echo "AWS_BUCKET    =   S3 Bucket to upload to"
    echo "NOOP          =   Set to 1 to do everything but upload"
    echo ""
    echo "Command:"
    echo "upload.sh <foldername>"
    echo ""
    exit 0
fi

MINSPACEFREE=1000000000
MAXRETRIES=3
SPLIT_MB="100m"
SPLIT_NUM=102400

############################################################################################################################
# CONFIG HANDLING
############################################################################################################################
FOLDER=$1

SHORTHOSTNAME=$(hostname -s)

if [ -z "$NOOP" ]; then
    NOOP=0
fi

if [ -z "$MAXTIME" ]; then
    echo '[!] MAXTIME not set in environment, setting to default of 300 seconds'
    MAXTIME=300
else
    echo "[+] Maximum runtime set to ${MAXTIME}"
fi

if [ -z "$TEMPARCHIVEDIR" ]; then
    echo '[!] TEMPARCHIVEDIR not set in environment, setting to default a randomly generated temp dir'
    RANDOMTEMPDIR=1
    TEMPARCHIVEDIR=$(mktemp -d)
else
    echo "[+] Temporary archive dir set to ${TEMPARCHIVEDIR}"
    RANDOMTEMPDIR=0
fi

if [ -z "$AWS_BUCKET" ]; then
    echo "[x] Please set a bucket name in the environment variable AWS_BUCKET"
    exit 1
fi

# make sure you set a profile
if [ -z "$AWS_PROFILE" ]; then
    if [ "$(grep -E '^\[default\]' ~/.aws/credentials)" -eq 1 ]; then
        AWS_PROFILE="default"
        echo "[+] AWS profile set to default"
    else
        echo "[x] AWS profile default not found and not specified in AWS_PROFILE environment varilable, please specify one."
        exit 1
    fi
else
    echo "[+] Using AWS profile ${AWS_PROFILE}"
fi
# make sure the AWS_PROFILE exists
PROFILEVALID=$(grep -E -c "^\[${AWS_PROFILE}" ~/.aws/credentials)
if [ "$PROFILEVALID" -eq 0 ]; then
    echo "[x] No profile found called '${AWS_PROFILE}', quitting"
    exit 1
elif [ "$PROFILEVALID" -ne 1 ]; then
    echo "[x] Either profile is invalid or more than one line found containing '${AWS_PROFILE}', quitting"
    exit 1
else
    PROFILEVALID=""
fi

if [ ! -d "${FOLDER}" ]; then
    echo "[x] '${FOLDER}' does not exist"
fi

s3Key=$(grep -A3 $AWS_PROFILE ~/.aws/credentials | grep aws_access_key_id | head -n1 | awk -F'=' '{print $NF}'| tr -d '[:space:]')
if [ -z "$s3Key" ]; then
    echo "Access key not found in config for profile $AWS_PROFILE"
    exit 1
fi

s3Secret=$(grep -A3 $AWS_PROFILE ~/.aws/credentials | grep aws_secret_access_key | head -n1 | awk -F'=' '{print $NF}'| tr -d '[:space:]')
if [ -z "$s3Secret" ]; then
    echo "Access Secret not found in config for profile $AWS_PROFILE"
    exit 1
fi

if [ -z "$AWS_REGION" ]; then
    AWS_REGION=$(grep -A5 $AWS_PROFILE ~/.aws/credentials | grep -E '^region' | head -n1 | awk -F'=' '{print $NF}'| tr -d '[:space:]')
    if [ -z "${AWS_REGION}" ]; then
        echo "[x] AWS_REGION environment variable not set and could not find it in your profile, quitting."
        exit 1
    else
        echo "[+] Extracted AWS_REGION from profile: ${AWS_REGION}"
    fi
else
    echo "[+] AWS region set from environment: ${AWS_REGION}"
fi

############################################################################################################################
# FUNCTION DEFINITIONS
############################################################################################################################

s3upload () {
    # uploads a file to the configured bucket
    # sets UPLOADSTATUS
    if [ -z "$1" ] || [ "$(echo -n "$1" | tr -d '[:space:]')" == "" ]; then
        echo "[!] s3upload() with no path, exiting"
        exit 1
    fi

    if [ -n "$2" ]; then
        RETRIES=$2
        if [ $RETRIES -gt $MAXRETRIES ]; then
            echo "[x] More than ${MAXRETRIES} retries, giving up."
            echo "[x] s3upload(${AWS_BUCKET}/${file}) failed: http status code: $UPLOADSTATUS"
            echo "###############################################"
            echo "$RETVAL"
            echo "###############################################"
            echo "[!] Removing temp file ${TEMPARCHIVEDIR}/${file}"
            rm -f "${TEMPARCHIVEDIR}/${file}"
            exit 1
        fi
    else
        RETRIES=1
    fi

    local file
    local dateValue
    local stringToSign
    local signature
    local RETVAL
    
    file=$(echo "$1" | awk -F'/' '{print $NF }')

    echo "[>] s3upload(${file}) starting"
    dateValue="$(date -R)"
    stringToSign="PUT\n\napplication/x-compressed-tar\n${dateValue}\n/${AWS_BUCKET}/${file}"
    signature=$(echo -en "${stringToSign}" | openssl sha1 -hmac "${s3Secret}" -binary | base64)
    # echo "[>] Uploading ${bucket}/${file}"
    if [ "$NOOP" -eq 0 ]; then
        RETVAL=$(curl -D - -s -X PUT -T "${TEMPARCHIVEDIR}/${file}" \
            -H "Host: ${AWS_BUCKET}.s3.amazonaws.com" \
            -H "Date: ${dateValue}" \
            -H "Content-Type: application/x-compressed-tar" \
            -H "Authorization: AWS ${s3Key}:${signature}" \
            "https://${AWS_BUCKET}.s3-${AWS_REGION}.amazonaws.com/${file}" 2>&1 )
    else
        echo "[!] Skipping upload, setting it as successful for debugging"
        RETVAL="HTTP/1.1 200"
    fi
    UPLOADSTATUS=$( echo "${RETVAL}" | grep -E '^HTTP' |  awk '{print $2}' | tail -n1 | tr -d '[:space:]')

    if [ $UPLOADSTATUS -eq 200 ]; then
        echo "[<] s3upload(${AWS_BUCKET}/${file}) success"
        echo "[!] Removing temp file ${TEMPARCHIVEDIR}/${file}"
        rm -f "${TEMPARCHIVEDIR}/${file}"
    else
        echo "[!] Something failed, trying again in 30 seconds, attempt #${RETRIES}"
        echo "curl output:"
        echo "${RETVAL}"
        sleep 30
        s3upload "$1" "$($RETRIES + 1)"
    fi
}

s3checkfile () {
    # "returns" filestatus
    local file
    local dateValue
    local stringToSign
    local signature
    local RETVAL
    
    file=$(echo "$1" | awk -F'/' '{print $NF }')
    echo "[>] s3checkfile(${file}) starting"
    filestatus=0
    
    dateValue=$(date -R)
    
    stringToSign="HEAD\n\napplication/x-compressed-tar\n${dateValue}\n/${AWS_BUCKET}/${file}"
    signature=$(echo -en "${stringToSign}" | openssl sha1 -hmac "${s3Secret}" -binary | base64)
    if [ $NOOP -eq 0 ]; then
        RETVAL=$(curl -s -I -D - \
            -H "Host: ${AWS_BUCKET}.s3.amazonaws.com" \
            -H "Date: ${dateValue}" \
            -H "Content-Type: application/x-compressed-tar" \
            -H "Authorization: AWS ${s3Key}:${signature}" \
            "https://${AWS_BUCKET}.s3-${AWS_REGION}.amazonaws.com/${file}" 2>&1)
        # we just want the http response code from the curl
        filestatus=$(echo "${RETVAL}" | grep -E '^HTTP' | awk '{print $2}' | head -n1 )
    else
        echo "[!] Skipping check, setting it as successful for debugging"
        filestatus="200"
    fi
    echo "[<] s3checkfile(${file}) == ${filestatus}"
}

compressfolder () {
    # sets 
    # FILENAME (short filename) and 
    # TARFILE, the full path to the tar
    
    local index
    local splunkbucket
    local ARCHIVEFOLDER
    local FOLDERSIZE

    ARCHIVEFOLDER="$1"

    
    index=$(echo "${ARCHIVEFOLDER}" | awk -F'/' '{print $(NF-2)}')
    splunkbucket=$(echo "${ARCHIVEFOLDER}" | awk -F'/' '{print $NF}')
    FILENAME="${SHORTHOSTNAME}-${index}-${splunkbucket}.tar"
    TARFILE="${TEMPARCHIVEDIR}/${FILENAME}"

    FOLDERSIZE=$(du -B1024 -s "${ARCHIVEFOLDER}" | awk -F' ' '{print $1}')

    echo "[!] Folder size: ${FOLDERSIZE}K"
    
    if [ $NOOP -eq 1 ]; then
        echo "[!] NOOP compressfolder(${ARCHIVEFOLDER})"
    else
        echo "[>] compressfolder(${ARCHIVEFOLDER}) Starting"
        if [ $FOLDERSIZE -gt $SPLIT_NUM ]; then
            echo "[!] splitting into ${SPLIT_MB} chunks"
            tar --no-acls -cf - "${ARCHIVEFOLDER}" | split -b "${SPLIT_MB}" - "${TARFILE}." 
            echo "[!] Combined archive size: $(du -sh "${TARFILE}.*")"
        else
            tar --no-acls -cf "${TARFILE}" "${ARCHIVEFOLDER}"
            echo "[!] Archive size: $(du -sh "${TARFILE}")"
        fi
        echo "[<] compressfolder(${ARCHIVEFOLDER}) == ${TARFILE}"
    fi
    }


updateruntime () {
    # updates the current runtime of the script for the while loop
    RUNTIME=$(($(date +%s) - STARTTIME))
    echo "[!] Current runtime: $RUNTIME secs"
    if [ "$RUNTIME" -gt $MAXTIME ]; then
        echo "[!] Time's up, quitting"
        exit 1
    fi
}

STARTTIME=$(date +%s)
RUNTIME=0

# only run while we need to
echo "[!] Starting upload.sh main loop"
while [ $RUNTIME -lt $MAXTIME ]; do
    # keep a minimum of a GB free on the disk
    SPACEFREE=$(df -B1 "${TEMPARCHIVEDIR}" | grep -v -E 'U.*\s+A.*\s+U.*' | awk '{print $3 }' | tr -d '[:space:]')
    echo "[!] Free disk: ${SPACEFREE}"
    if [ $SPACEFREE -lt $MINSPACEFREE ]; then
        echo "Space less than ${MINSPACEFREE}, quitting"
        exit 1
    fi

    for FOLDERNAME in $(find "${FOLDER}" -maxdepth 2 -type d | grep 'db/db_'); do
        echo "[>] Main loop handling ${FOLDERNAME}"
        compressfolder "${FOLDERNAME}"
        
        for FILENAME in $(find "${TEMPARCHIVEDIR}" -maxdepth 1 -type f -name '*.tar*'); do
            s3checkfile "${FILENAME}"
            
            if [ "${filestatus}" -eq 404 ]; then
                s3upload "${FILENAME}"
                sleep 5
            elif [ "$filestatus" -eq 200 ]; then 
                echo "[-] ${FILENAME} exists, skipping"
            else
                echo "[x] Error checking status of ${FILENAME} error code: ${filestatus}"
                exit 1
            fi
        done;

        echo "[<] Main loop handling ${FOLDERNAME} done"
        updateruntime
    done
    break
done
if [ $RANDOMTEMPDIR -eq 1 ]; then
    echo "[>] Removing randomly-generated temporary archive dir..."
    rm -rf "$TEMPARCHIVEDIR"
    echo "[<] Completed"
else
    echo "[!] Temporary archive dir set to ${TEMPARCHIVEDIR}, $(find "${TEMPARCHIVEDIR}"  -type f | wc -l) files currently there, you might want to check and clean up."
fi

echo "[!] Done!"
