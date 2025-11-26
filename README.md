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
