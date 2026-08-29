{
  security = {
    # Required for the circuit breaker to be a circuit breaker. deploy-rs
    # activates as root over an unprivileged ssh login, and an automatic
    # rollback that stops to ask a human for a sudo password is not automatic.
    #
    # The trade is small here: ssh is key-only (PasswordAuthentication = false,
    # KbdInteractiveAuthentication = false), so anyone who can reach a shell as
    # hutao already holds a private key, and the sudo password protects nothing
    # they could not get by other means.
    sudo.wheelNeedsPassword = false;

    auditd.enable = true;
    audit = {
      enable = true;
      rules = [
        "-a always,exit -F path=/etc/passwd -F perm=wa -F key=identity"
        "-a always,exit -F path=/etc/group -F perm=wa -F key=identity"
        "-a always,exit -F path=/etc/shadow -F perm=wa -F key=identity"
        "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -F key=modules"
        "-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -F key=time-change"
        "-a always,exit -F arch=b64 -C euid!=uid -F euid=0 -S execve -F key=privesc"
      ];
    };
  };
}
