import subprocess
import sys
import os

def run_git_command(args):
    try:
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None

def check_zig_changes():
    last_tag = run_git_command(["git", "describe", "--tags", "--abbrev=0"])
    
    if not last_tag:
        print("No tags found, assuming initial release.")
        return True

    print(f"Comparing HEAD against last tag: {last_tag}")
    # Get list of changed files
    diff_output = run_git_command(["git", "diff", "--name-only", last_tag, "HEAD"])
    
    if not diff_output:
        print("No file changes found.")
        return False
        
    for file_path in diff_output.split('\n'):
        if file_path.strip().endswith('.zig'):
            print(f"Found changed zig file: {file_path}")
            return True
            
    print("No .zig files changed.")
    return False

if __name__ == "__main__":
    should_release = check_zig_changes()
    print(f"Should release: {should_release}")
    
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"should_release={'true' if should_release else 'false'}\n")
