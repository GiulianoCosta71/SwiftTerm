//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

import Foundation
#if !os(iOS) && !os(tvOS) && !os(Windows)

/**
 * APIs to assist in controlling a Unix pseudo-terminal from Swift.
 *
 *This provides a wrapper for
 * the libc `forkpty`API in the form of `fork(andExec:args:env:desiredWindowSize:` method,
 * `setWinSize` and `availableBytes`
 */
public class PseudoTerminalHelpers {
    private struct CStringArray {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int
    }

    private static func allocateCStringArray(_ strings: [String]) -> CStringArray? {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var initializedCount = 0

        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                for cleanupIndex in 0..<initializedCount {
                    free(base[cleanupIndex])
                }
                base.deallocate()
                return nil
            }
            base[index] = duplicated
            initializedCount += 1
        }

        base[strings.count] = nil
        return CStringArray(base: base, count: strings.count)
    }

    private static func freeCStringArray(_ array: CStringArray) {
        for index in 0..<array.count {
            free(array.base[index])
        }
        array.base.deallocate()
    }

    /**
     * This method both forks and executes the provided command under a Pseudo Terminal (pty)
     * - Parameter andExec: the name of the executable to run
     * - Parameter args: arguments to be passed to the executable
     * - Parameter env: the environment variables for the child process
     * - Parameter desiredWindowSize: the window size that will be set on the pseudo terminal.
     *
     * - Returns: nil on error, or a tuple containing the process ID, and the file descriptor to the primary side of the newly created pseudo-terminal.
     */
    public static func fork (andExec: String, args: [String], env: [String], currentDirectory: String? = nil, desiredWindowSize: inout winsize) -> (pid: pid_t, masterFd: Int32)?
    {
        guard let cArgs = allocateCStringArray(args) else {
            return nil
        }
        guard let cEnv = allocateCStringArray(env) else {
            freeCStringArray(cArgs)
            return nil
        }
        guard let cExecutable = strdup(andExec) else {
            freeCStringArray(cEnv)
            freeCStringArray(cArgs)
            return nil
        }

        var cCurrentDirectory: UnsafeMutablePointer<CChar>?
        if let currentDirectory {
            guard let duplicatedCurrentDirectory = strdup(currentDirectory) else {
                free(cExecutable)
                freeCStringArray(cEnv)
                freeCStringArray(cArgs)
                return nil
            }
            cCurrentDirectory = duplicatedCurrentDirectory
        }

        defer {
            freeCStringArray(cArgs)
            freeCStringArray(cEnv)
            free(cExecutable)
            if let cCurrentDirectory {
                free(cCurrentDirectory)
            }
        }

        var master: Int32 = 0

        // Descriptors to close in the child, collected here because the child
        // may only make async-signal-safe calls. Listing the open ones is far
        // cheaper than closing every possible number (tens of thousands).
        let inherited = openDescriptorsAbove2()
        defer { inherited.deallocate() }
        
        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            return nil
        }
        if pid == 0 {
            if let cCurrentDirectory {
                _ = chdir(cCurrentDirectory)
            }
            // Keep nothing but the terminal: descriptors the host opened without
            // close-on-exec (by other libraries, or received from another
            // process) must not reach the child. Only async-signal-safe calls
            // here, the host may be multithreaded.
            if inherited.count >= 0 {
                var i = 0
                while i < inherited.count {
                    _ = close(inherited.base[i])
                    i += 1
                }
            } else {
                let maxDescriptor = min(Int32(getdtablesize()), 65_536)
                var fd: Int32 = 3
                while fd < maxDescriptor {
                    _ = close(fd)
                    fd += 1
                }
            }
            
            _ = execve(cExecutable, cArgs.base, cEnv.base)
            _exit(127)
        }
        // The primary side belongs to this process only. Without close-on-exec every
        // child started later (another terminal, a helper spawned with fork/exec) would
        // inherit it, could read and write this terminal, and would keep it open after
        // this process exits, so the child here would not get SIGHUP. forkpty has no
        // flag for this; between forkpty and fcntl another thread could still fork,
        // callers that start terminals from several threads must serialize that.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (pid, master)
    }
    
    /// Open descriptors of this process from 3 up, in memory the child can
    /// read without allocating. `count == -1` when the list is unavailable;
    /// the child then closes every number up to the descriptor limit.
    struct DescriptorList {
        let base: UnsafeMutablePointer<Int32>
        let count: Int
        func deallocate() { base.deallocate() }
    }

    static func openDescriptorsAbove2() -> DescriptorList {
        #if os(macOS)
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        if needed > 0 {
            // Room for descriptors opened meanwhile.
            let capacity = Int(needed) / stride + 64
            let infos = UnsafeMutablePointer<proc_fdinfo>.allocate(capacity: capacity)
            defer { infos.deallocate() }
            let got = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, infos, Int32(capacity * stride))
            if got > 0 {
                let n = Int(got) / stride
                let base = UnsafeMutablePointer<Int32>.allocate(capacity: max(n, 1))
                var count = 0
                for i in 0..<n where infos[i].proc_fd >= 3 {
                    base[count] = infos[i].proc_fd
                    count += 1
                }
                return DescriptorList(base: base, count: count)
            }
        }
        #endif
        return DescriptorList(base: UnsafeMutablePointer<Int32>.allocate(capacity: 1), count: -1)
    }

    /**
     * Sets the window size of the underlying pseudo terminal.
     * - Parameter masterPtyDescriptor: a pseudo-terminal master file descriptor, as returned by fork(andExec:)
     * - Returns: the value from calling the ioctl
     */
    public static func setWinSize (masterPtyDescriptor: Int32, windowSize: inout winsize) -> Int32
    {
#if os(macOS)
        return ioctl(masterPtyDescriptor, TIOCSWINSZ, &windowSize)
#else
	return ioctl(masterPtyDescriptor, UInt(TIOCSWINSZ), &windowSize)
#endif
    }
    
    /**
     * Returns the number of available bytes to be read from the file descriptor
     */
    public static func availableBytes (fd: Int32) -> (status: Int32, size: Int32)
    {
        var size: Int32 = 0
        let status = ioctl (fd, 0x4004667f /* FIONREAD */, &size)
        return (status, size)
    }
}
#endif
