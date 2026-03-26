function work-vnc --description "SSH into server, start VNC, forward port, launch vncviewer"
    if test (count $argv) -lt 1
        echo "Usage: work-vnc user@server-ip [--no-auth] [--mirror] [--install]"
        return 1
    end

    set -l SERVER $argv[1]
    set -l VNC_DISPLAY ":1"
    set -l VNC_PORT "5901"
    set -l LOCAL_PORT "5901"
    set -l RESOLUTION "1920x1080"
    set -l SOCK "/tmp/work-vnc-ssh-sock"
    set -l NO_AUTH 0
    set -l MIRROR 0
    set -l INSTALL 0

    if contains -- --no-auth $argv
        set NO_AUTH 1
    end
    if contains -- --mirror $argv
        set MIRROR 1
    end
    if contains -- --install $argv
        set INSTALL 1
    end

    # Check local dependencies
    if not command -q vncviewer
        echo "Error: vncviewer not found locally."
        echo "Install with: sudo pacman -S tigervnc"
        return 1
    end

    # Open a shared SSH connection (authenticates once)
    echo "Connecting to $SERVER..."
    ssh -fNM -S $SOCK $SERVER

    if test $status -ne 0
        echo "SSH connection failed."
        return 1
    end

    # Determine required command and package
    set -l CMD "vncserver"
    set -l PKG "tigervnc-standalone-server"
    if test $MIRROR -eq 1
        set CMD "x0vncserver"
        set PKG "tigervnc-scraping-server"
    end

    # Check/install server dependencies
    if not ssh -S $SOCK $SERVER "command -v $CMD >/dev/null 2>&1"
        if test $INSTALL -eq 1
            echo "Installing $PKG on server..."
            ssh -S $SOCK -t $SERVER "sudo apt install -y $PKG"
            if test $status -ne 0
                echo "Failed to install $PKG."
                ssh -S $SOCK -O exit $SERVER 2>/dev/null
                return 1
            end
        else
            echo "Error: $CMD not found on server."
            echo "Re-run with --install to install it automatically."
            ssh -S $SOCK -O exit $SERVER 2>/dev/null
            return 1
        end
    end

    if test $MIRROR -eq 1
        # Share the real server desktop (display :0)
        set VNC_PORT "5900"
        set LOCAL_PORT "5900"

        echo "Starting x0vncserver on $SERVER (mirroring real desktop)..."
        if test $NO_AUTH -eq 1
            ssh -S $SOCK $SERVER "pkill x0vncserver 2>/dev/null; nohup x0vncserver -localhost yes -SecurityTypes None -display :0 </dev/null >/dev/null 2>&1 & nohup env DISPLAY=:0 vncconfig -nowin </dev/null >/dev/null 2>&1 &"
        else
            ssh -S $SOCK $SERVER "pkill x0vncserver 2>/dev/null; nohup x0vncserver -localhost yes -display :0 </dev/null >/dev/null 2>&1 & nohup env DISPLAY=:0 vncconfig -nowin </dev/null >/dev/null 2>&1 &"
        end
    else
        # Start a separate VNC session
        echo "Starting VNC server on $SERVER..."
        if test $NO_AUTH -eq 1
            ssh -S $SOCK $SERVER "vncserver -kill $VNC_DISPLAY 2>/dev/null; vncserver $VNC_DISPLAY -geometry $RESOLUTION -localhost yes -SecurityTypes None && nohup env DISPLAY=$VNC_DISPLAY vncconfig -nowin </dev/null >/dev/null 2>&1 &"
        else
            ssh -S $SOCK $SERVER "vncserver -kill $VNC_DISPLAY 2>/dev/null; vncserver $VNC_DISPLAY -geometry $RESOLUTION -localhost yes && nohup env DISPLAY=$VNC_DISPLAY vncconfig -nowin </dev/null >/dev/null 2>&1 &"
        end
    end

    if test $status -ne 0
        echo "Failed to start VNC server."
        ssh -S $SOCK -O exit $SERVER 2>/dev/null
        return 1
    end

    echo "Starting SSH tunnel (local $LOCAL_PORT → remote $VNC_PORT)..."
    ssh -S $SOCK -fNL "$LOCAL_PORT:localhost:$VNC_PORT" $SERVER

    sleep 2

    echo "Launching vncviewer..."
    vncviewer "localhost:$LOCAL_PORT"

    echo "Shutting down..."
    if test $MIRROR -eq 1
        ssh -S $SOCK $SERVER "pkill x0vncserver 2>/dev/null"
    else
        ssh -S $SOCK $SERVER "vncserver -kill $VNC_DISPLAY 2>/dev/null"
    end
    ssh -S $SOCK -O exit $SERVER 2>/dev/null
    echo "Done."
end
