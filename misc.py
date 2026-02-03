import subprocess

def sh(command, log_limit=1024, cwd=None, env=None):   
    proc = subprocess.Popen(
        args=command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        shell=True,
        bufsize=1)
    lines = []
    truncated = False
    with proc.stdout:
        for line in proc.stdout:
            line = line.decode()
            lines.append(line)
            line = line.rstrip()
            if len(line) > log_limit:
                truncated = True
                print(line[:log_limit] +
                          "... (truncated to the first " + str(log_limit) +
                          " characters)")
            else:
                print(line)
    output = "".join(lines)
    if proc.wait() != 0:
        if truncated:
            log.error(command + " replay full stdout/stderr"
                      " because an error occurred and some of"
                      " it was truncated")
            log.error(output)
        raise subprocess.CalledProcessError(
            returncode=proc.returncode,
            cmd=command,
            output=output
        )
    return output

sh("openstack --quiet image list -f json --limit 2000 --private --property name='teuthology-centos-9.stream-x86_64'")
