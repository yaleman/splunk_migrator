#!/bin/bash
# s3 upload stuff sourced from http://tmont.com/blargh/2014/1/uploading-to-s3-in-bash

if [ $1 == "-h" ]; then
    echo "Environment variables to configure this:"
    echo "MAXTIME       =   Will automatically quit after this many seconds"
    echo "AWS_PROFILE   =   AWS profile to use"
    echo "AWS_REGION    =   AWS region the bucket is in (Region is optional, if you don't set it, I'll try and get it from ~/.aws/credentials)"
    echo "AWS_BUCKET    =   S3 Bucket to upload to"
    echo ""
    echo "Command:"
    echo "upload.sh <foldername>"
    echo ""
    exit 0
fi



############################################################################################################################
# CONFIG HANDLING
############################################################################################################################
FOLDER=$1



if [ -z $MAXTIME ]; then
    echo '[!] MAXTIME not set in environment, setting to default of 300 seconds'
    MAXTIME=300
else
    echo '[+] Maximum runtime set to ${MAXTIME}'
fi

if [ -z $TEMPARCHIVEDIR ]; then
    echo '[!] TEMPARCHIVEDIR not set in environment, setting to default a randomly generated temp dir'
    RANDOMTEMPDIR=1
    TEMPARCHIVEDIR=$(mktemp -d)
else
    echo '[+] Temporary archive dir set to ${TEMPARCHIVEDIR}'
    RANDOMTEMPDIR=0
fi

if [ -z $AWS_BUCKET ]; then
    echo "[x] Please set a bucket name in the environment variable AWS_BUCKET"
    exit 1
fi

# make sure you set a profile
if [ -z $AWS_PROFILE ]; then
    if [ $(egrep -c '^\[default\]' ~/.aws/credentials) -eq 1 ]; then
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
PROFILEVALID=$(egrep -c "^\[${AWS_PROFILE}" ~/.aws/credentials)
if [ $PROFILEVALID -eq 0 ]; then
    echo "[x] No profile found called '${AWS_PROFILE}', quitting"
    exit 1
elif [ $PROFILEVALID -ne 1 ]; then
    echo "[x] Either profile is invalid or more than one line found containing '${AWS_PROFILE}', quitting"
    exit 1
else
    PROFILEVALID=""
fi

if [ ! -d "${FOLDER}" ]; then
    echo "[x] '${FOLDER}' does not exist"
fi

s3Key=$(grep -A3 $AWS_PROFILE ~/.aws/credentials | grep aws_access_key_id | head -n1 | awk -F'=' '{print $NF}')
if [ -z $s3Key ]; then
    echo "Access key not found in config for profile $AWS_PROFILE"
    exit 1
fi

s3Secret=$(grep -A3 $AWS_PROFILE ~/.aws/credentials | grep aws_secret_access_key | head -n1 | awk -F'=' '{print $NF}')
if [ -z $s3Secret ]; then
    echo "Access Secret not found in config for profile $AWS_PROFILE"
    exit 1
fi

if [ -z $AWS_REGION ]; then
    AWS_REGION=$(grep -A5 $AWS_PROFILE ~/.aws/credentials | egrep '^region' | head -n1 | awk -F'=' '{print $NF}')
    if [ -z AWS_REGION ]; then
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

# uploads a file to the configured bucket
s3upload () {
    file=$1
    echo "[>] s3upload(${file}) starting"
    dateValue=`date -R`
    stringToSign="PUT\n\napplication/x-compressed-tar\n${dateValue}\n/${bucket}/${file}"
    signature=`echo -en ${stringToSign} | openssl sha1 -hmac ${s3Secret} -binary | base64`
    # echo "[>] Uploading ${bucket}/${file}"
    RETVAL=$(curl -D - -s -X PUT -T "${TEMPARCHIVEDIR}/${file}" \
        -H "Host: ${bucket}.s3.amazonaws.com" \
        -H "Date: ${dateValue}" \
        -H "Content-Type: application/x-compressed-tar" \
        -H "Authorization: AWS ${s3Key}:${signature}" \
        https://${bucket}.s3-${AWS_REGION}.amazonaws.com/${file} 2>&1 )
    UPLOADSTATUS=$( echo "${RETVAL}" | grep -v '100 Continue' | egrep '^HTTP' |  awk '{print $2}' | head -n1 )
    if [ $UPLOADSTATUS -eq 200 ]; then
        echo "[<] s3upload(${bucket}/${file}) success"
    else
        echo "[x] s3upload(${bucket}/${file}) failed: http status code: $UPLOADSTATUS"
        echo "###############################################"
        echo "$RETVAL"
        echo "###############################################"
        exit 1
    fi
    # reset variables
    RETVAL=""
    stringToSign=""
    signature=""
    dateValue=""

}

s3checkfile () {
    file=$1
    echo "[>] s3checkfile(${file}) starting"
    filestatus=0
    dateValue=`date -R`
    stringToSign="HEAD\n\napplication/x-compressed-tar\n${dateValue}\n/${bucket}/${file}"
    signature=`echo -en ${stringToSign} | openssl sha1 -hmac ${s3Secret} -binary | base64`
    RETVAL=$(curl -I -s -D - \
        -H "Host: ${bucket}.s3.amazonaws.com" \
        -H "Date: ${dateValue}" \
        -H "Content-Type: application/x-compressed-tar" \
        -H "Authorization: AWS ${s3Key}:${signature}" \
        https://${bucket}.s3-${AWS_REGION}.amazonaws.com/${file}  2>&1 \
        | egrep '^HTTP' | awk '{print $2}' | head -n1 )
    filestatus=$RETVAL
    echo "[<] s3checkfile(${file}) == ${filestatus}"
    # reset variables
    RETVAL=""
    signature=""
    stringToSign=""
    dateValue=""
}

compressfolder () {
    # sets FILENAME (short filename) and TARFILE, the full path to the tar
    ARCHIVEFOLDER="$1"
    echo "[>] compressfolder(${ARCHIVEFOLDER}) Starting"
    splunkbucket=$(echo "${ARCHIVEFOLDER}" | awk -F'/' '{print $NF}')
    index=$(echo "${ARCHIVEFOLDER}" | awk -F'/' '{print $(NF-2)}')
    shorthost=$(hostname -s)

    FILENAME="${shorthost}-${index}-${splunkbucket}.tar"
    TARFILE="/var/log/splunkcold/${FILENAME}"

    tar --no-acls -cf "${TARFILE}" "${ARCHIVEFOLDER}"

    echo "[<] compressfolder(${ARCHIVEFOLDER}) Done"
    splunkbucket=""
    index=""
    shorthost=""
    ARCHIVEFOLDER=""
    }


updateruntime () {
    # updates the current runtime of the script for the while loop
    RUNTIME=$(expr $(date +%s) - $STARTTIME )
    echo "[!] Current runtime: $RUNTIME secs"
    if [ $RUNTIME -gt $MAXTIME ]; then
        echo "[!] Time's up, quitting"
        exit 1
    fi
}

STARTTIME=$(date +%s)
RUNTIME=0

# only run while we need to
echo "starting"
while [ $RUNTIME -lt $MAXTIME ]; do
    echo "."
    for FOLDERNAME in $(find "${FOLDER}" -maxdepth 2 -type d | grep 'db/db_'); do
        echo "[>] Main loop handling ${FOLDERNAME}"
        compressfolder "${FOLDERNAME}"

        s3checkfile "${FILENAME}"
        if [ $filestatus -eq 404 ]; then
            s3upload "${FILENAME}"
        elif [ $filestatus -eq 200 ]; then 
            echo "[-] ${FILENAME} exists, skipping"
        else
            echo "[x] Error checking status of ${FILENAME} error code: ${filestatus}"
            exit 1
        fi
        rm "${TARFILE}"

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
    echo "[!] Temporary archive dir set to ${TEMPARCHIVEDIR}, $(ls -1 $TEMPARCHIVEDIR | wc -l) files currently there, you might want to check and clean up."
fi

echo "[!] Done!"
