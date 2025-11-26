#!/usr/bin/env bash

#PROJECT_DEFAULTS
#-------------------------------------------------------------------------------
IFS=$'\n'
DEFAULT_PROJECT="*"
DEFAULT_ZONE="us-east-1*"
DEFAULT_STORAGE_METHOD="memory"
DEFAULT_SKIP_PACKAGE_VERIFY="False"
DEFAULT_GLOBAL_ERROR_LEVEL=2
DEFAULT_ASG_CHECK="?!not_null(Tags[?Key == 'aws:autoscaling:groupName'.Value)"
#-------------------------------------------------------------------------------

#Array Initialization
#-------------------------------------------------------------------------------
declare -a VALID_PACKAGE_MANAGERS=(dnf yum apt pacman snap)
declare -a REQUIRED_PACKAGES=(jq openssl aws)
declare -a ERROR_CHECK=(VALIDATE_VAR VALIDATE_JSON GET_PACKAGE_MANAGER GET_SHELL VALIDATE_PACKAGES)
declare -a workerPids()
declare -a usedFDs=()

declare -A VARIABLE_DESC
VARIABLE_DESC[instanceInfo]="AWS EC2 Describe results"
VARIABLE_DESC[storageMethod]="storage method"
VARIABLE_DESC[arrLength]="returned EC2 describe JSON"

declare -A ERROR_LEVELS
ERROR_LEVELS[info]=0
ERROR_LEVELS[warn]=1
ERROR_LEVELS[error]=2
ERROR_LEVELS[debug]=3


#-------------------------------------------------------------------------------


for i in "${!ERROR_CHECK[@]}" ; do
    declare -r "${ERROR_CHECK[$i]}"="$i"
done

trap cleanup_helper EXIT


#Help Menu (Make a man page later that no one will probably ever read)
#-------------------------------------------------------------------------------
help_menu(){
    echo -e '\n
    SSJFaster is a tool that will dynamically generate you ansible inventories from AWS. It is called SSJFaster because my old script was slow and I like DragonBall and Saiyans are fast and cool like this script.
    
    Options:
    -p | --project            : Specifies a project tag to pull. Defaults to all
    -b | --forks              : Specify max background processes to spawn. Defaults to 1
    -z | --zone               : Which AZ to look in. If not set all AZ will be looked at.
    -m | --method             : Choose temp file storage method (memory, disk). Defaults to memory. Disk uses your home dir.
    -a | --includeautoscaling : if -a is set script will include ASG nodes. Skips by default.
    -e | --error-level        : choose output verbosity. Info=0,Warn=1,Error=2,Debug=3. Default 2
    --skip-package-verify     : Skips verification check for required VALIDATE_PACKAGES
    -h | --help               : You are here now
    -v | --version            : give version info'
}

#-------------------------------------------------------------------------------

#Error Handling/Logging
#-------------------------------------------------------------------------------

console_logger(){
    #Custom console logger
    local yellow="\e[40;0;33m"
    local red="\e[40;0;31m"
    local green="\e[40;0;32m"
    local white="\e[40;0;37m"
    local clear="\e[0m"
    local prefix=""
    local error_level=${desired_error_level:-}
    local message_level=$1
    local message=$2
    
    case $message_level in
        0) prefix="${white}[INFO]${clear}" ;;
        1) prefix="${yellow}[WARN]${clear}" ;;
        2) prefix="${red}[ERROR]${clear}" ;;
        3) prefix="${green}[DEBUG]${clear}" ;;
    esac
    
    if [[ "$error_level" -ge "$message_level" ]] ; then
        echo -e "$(date +%H:%M%S) $prefix $message"
    fi
}

error_check(){
    case $1 in
        VALIDATE_VAR )
            local VARIABLE_VALUE="$2"
            local VARIABLE_NAME="$3"
            [[ -z "$VARIABLE_VALUE" ]] && raise_error 1102 "$VARIABLE_NAME"
            ;;
        VALIDATE_JSON )
            local JSON_OBJECT="$2"
            local JSON_OBJECT_NAME="$3"
            if ! jq . <<< "$JSON_OBJECT" &>/dev/null ; then raise_error 1103 "$JSON_OBJECT_NAME" ; fi
            ;;
        GET_PACKAGE_MANAGER )
            local POSSIBLE_MANAGERS=("${@:2}")
            declare -g PACKAGE_MANAGER
            for MANAGER in "${POSSIBLE_MANAGERS[@]}" ; do
                if which $MANAGER &>/dev/null ; then PACKAGE_MANAGER="$MANAGER" ; break ; fi
            done
            [[ -z "$PACKAGE_MANAGER" ]] && raise_error 1105 ; fi
            ;;
        GET_SHELL )
            [[ ! ${SHELL##*/} == "bash" ]] && raise_error 1109
        VALIDATE_PACKAGES )
            local REQUIRED_PACKAGES=("${@:2}")
            for PACKAGE in "${REQUIRED_PACKAGES[@]}" ; do
                [[ $? -eq 1 ]] && raise_error 1106 "$PACKAGE"
            done
            ;;
        esac
}

raise_error(){
    local ERROR_CODE=$1
    case $ERROR_CODE in
        1101 )
            local PROJECT_NAME="$2"
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : Named pipe ${PROJECT_NAME}.fifo already exists. Please clean this up before running again" >&2
            ;;
        1102 )
            local VARIABLE_NAME="$2"
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : ${VARIABLE_DESC[$VARIABLE_NAME]} are empty." >&2
            ;;
        1103 )
            local VARIABLE_NAME="$2"
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : Invalid JSON format returned from ${VARIABLE_DESC[$VARIABLE_NAME]}" >&2
            ;;
        1104 )
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : An invalid option/flag was used" >&2
            ;;
        1105 )
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : No valid package manager was found. The compatible package managers are \"${VALID_PACKAGE_MANAGERS[*]}\""
            ;;
        1106 )
            local PACKAGE_NAME="$2"
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : Required package $PACKAGE_NAME was not found. Please install and try again"
            ;;
        1107 )
            local VARIABLE_NAME="$2"
            local INVALID_SELECTION="$3"
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : Invalid value for ${VARIABLE_DESC[$VARIABLE_NAME]}: \"$INVALID_SELECTION\""
            ;;
        1108 )
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : Test error, raise me to test logging levels"
            ;;
        1109 )
            console_logger "${ERROR_LEVELS[error]}" "${ERROR_CODE} : Invalid shell $SHELL detected. Please use the Bourne Again Shell (bash)"
            ;;
        esac
    exit 1
}

#-------------------------------------------------------------------------------

#Main function
#-------------------------------------------------------------------------------
main(){
    
    [[ "${skipPackageVerify:-$DEFAULT_SKIP_PACKAGE_VERIFY}" == "False" ]] && error_check "${ERROR_CHECK[VALIDATE_PACKAGES]}" "${REQUIRED_PACKAGES[@]}"
    error_check "${ERROR_CHECK[GET_SHELL]}"
    
    instanceInfo=$(\
        aws ec2 describe-instances\ \
        --filters \
            "Name=tag:Project,Values=${checkProject:-$DEFAULT_PROJECT}" \
            "Name=availability-zone,Values=${availabilityZone:-$DEFAULT_ZONE}" \
        --query \
            "Reservations[].Instances[${asgString:-$DEFAULT_ASG_CHECK}]\
            .[InstanceId,PrivateIpAddress, Tags[?Key == 'Project'].Value]" \
        --output json\
        | jq -c
    )
    
    error_check "${ERROR_CHECK[VALIDATE_VAR]}" "$instanceInfo" "instanceInfo"
    error_check "${ERROR_CHECK[VALIDATE_JSON]}" "$instanceInfo" "instanceInfo"
    
    create_temp_directory
    make_project_pipes
    iterate_over_objects
    sleep 2 #Allows pipes to finish writing
    combine_from_temp_dir
    console_logger "${ERROR_LEVELS[info]}" "Done in $SECONDS second(s)!"
}
#-------------------------------------------------------------------------------

#Primary Worker Functions
#-------------------------------------------------------------------------------

iterate_over_objects(){
    local OBJECT_ITER=0
    local arrLength
    arrLength=$(jq length <<< "$instanceInfo")
    
    [[ "$arrLength" -eq 0 ]] && raise_error 1107 "arrLength" "$arrLength"
    
    while read -r JSON_ELEMENTS ; do
        
        fork_to_back "$JSON_ELEMENTS" &
        
        workerPids+=($!)
        ((OBJECT_ITER++))
        console_logger "${ERROR_LEVELS[info]}" "$OBJECT_ITER/$arrLength"
        
        if [[ "${#workerPids[@]}" == "${bgProc:-1}" ]] || [[ "$OBJECT_ITER" -eq "$arrLength" ]] ; then
            wait "${workerPids[@]}"
            workerPids=()
        fi
        
    done < <( jq -c .[] <<< "$instanceInfo" )
}

fork_to_back(){
    
    parsed_info="$1"
    
    if [[ -n "$asgString" ]] ; then
        instanceId=$(jq -r .[0] <<< "$parsed_info")
        privateIp=$(jq -r .[1]  <<< "$parsed_info")
        project=$(jq -r .[2][0] <<< "$parsed_info")
    else
        instanceId=$(jq .[0][0] <<< "$parsed_info")
        privateIp=$(jq .[0][1]  <<< "$parsed_info")
        project=$(jq .[0][2][0] <<< "$parsed_info")
    fi
    
    projectSanitized=$(cut -d '-' -f2 <<< "$project")
    
    [[ -n "$projectSanitized" ]] && printf "%4s%s\n%8s%s\n" "" "$instanceId" "" "ansible_host: $privateIp" > "${tempDir}/${projectSanitized}.fifo"
}

create_temp_directory(){
    
    case ${storageMethod:-$DEFAULT_STORAGE_METHOD} in
        memory)
            console_logger "${ERROR_LEVELS[info]}" "Storing temporary files in memory"
            tempDir=$(mktemp -d /dev/shm/SSJFast.XXXXXXXX)
            ;;
        disk)
            console_logger "${ERROR_LEVELS[info]}" "Storing temporary files on disk"
            tempDir=$(mkdir -d ~/SSJFast.XXXXXXXX)
            ;;
        *)
            raise_error 1107 "storageMethod" "$storageMethod"
            ;;
    esac
    
}

combine_from_temp_dir(){
    
    cat "${tempDir}/*.part" > "${tempDir}/masterInventory.yaml"
    mv "${tempDir}/masterInventory.yaml" ~/
    
}

make_project_pipes(){
    
    while read -r project ; do
    
        projectSanitized=$(cut -d '-' -f2 <<< "$project")
        
        if [[ -p "${projectSanitized}.fifo" ]] ; then
            raise_error 1101 "$projectSanitized"
        else
            mkfifo "${tempDir}/${projectSanitized}.fifo"
            exec {fdNum}<> "${tempDir}/${projectSanitized}.fifo"
            (
                while IFS= read -r line ; do
                    echo "$line" >> "${tempDir}/${projectSanitized}.part"
                done < "${tempDir}/${projectSanitized}.fifo"
            ) &
            
            printf "%s\n%2s%s\n" "$project:" "" "hosts:" > "${tempDir}/${projectSanitized}.fifo"
            
            declare -g "loggerPID_${projectSanitized}"=$!
            declare -n pid_ref=loggerPID_${projectSanitized}
            console_logger "${ERROR_LEVELS[debug]}" "Pipe succesfully made for $project with PID $pid_ref with an open file descriptor $fdNum"
            usedFDs+=("$fdNum")
        fi
    done < <( ( jq -r .[][][2][0] <<< "$instanceInfo" ) | sort -u )
    
}
#-------------------------------------------------------------------------------

#Cleanup
#-------------------------------------------------------------------------------
cleanup_helper(){
    printf "\n"
    clean_pipes_and_handles
    clean_loose_files
}

clean_pipes_and_handles(){
    for fd in "${usedFDs[@]}" ; do
        console_logger "${ERROR_LEVELS[debug]}" "Cleanup: Closing FD $fd"
        exec {fd}>&- &>/dev/null
    done
    
    while read -r project ; do
        projectSanitized=$(cut -d '-' -f2 <<< "$project")
        declare -n current_pid="loggerPID_${projectSanitized}"
        
        [[ -z "$current_pid" ]] || ( kill -15 "$current_pid" ; console_logger "${ERROR_LEVELS[debug]}" "Cleanup: Pipe process with PID $current_pid ended" )
        
    done < <( ( jq -r .[][][2][0] <<< "$instanceInfo" ) | sort -u )
    
}

clean_loose_files(){
    console_logger "${ERROR_LEVELS[info]}" "Removing temporary files"
    { [[ "$DESIRED_ERROR_LEVEL" -eq 4 ]] && rm -rfv "$tempDir" ; } || rm -rf "$tempDir"
    console_logger "${ERROR_LEVELS[info]}" "temporary files removed"
}
#-------------------------------------------------------------------------------

#Argument/Flag handler
#-------------------------------------------------------------------------------
args=$(2>/dev/null getopt -a -o p:b:z:t:m:e:ahv --long project:,forks:,zone:,method:,includeautoscaling,skip-package-verify,error-level,help,version -- "$@") || {
    raise_error 1104
}

eval set -- "${args}"
while :
do
    case $1 in
        -p | --project)             checkProject=$2 ; shift 2 ;;
        -b | --forks)               bgProc=$2 ; shift 2 ;;
        -z | --zone)                availabilityZone=$2 ; shift 2 ;;
        -m | --method)              storageMethod=$2 ; shift 2 ;;
        -e | --error-level)         $DESIRED_ERROR_LEVEL=$2 ; shift 2 ;;
        -a | --includeautoscaling)  asgString="" ; shift ;;
             --skip-package-verify) skipPackageVerify="True" ; shift ;;
        -h | --help)                help_menu ; exit 0 ;;
        -v | --version)             echo "Version 3.1" ; exit 0 ;;
        /?)                         echo "Invalid Option: Please consult the help documents with -h or --help"
        --)                         shift ; break ;;
    esac
done
#-------------------------------------------------------------------------------

main
