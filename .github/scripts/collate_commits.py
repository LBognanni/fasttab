import subprocess
import sys
import os
import re

def run_git_command(args):
    """Helper to run git commands and return output string."""
    try:
        result = subprocess.run(
            args, 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE, 
            text=True, 
            check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError:
        return None

def get_commit_messages():
    """Gets commit messages since the last tag."""
    # 1. Try to find the latest tag
    last_tag = run_git_command(["git", "describe", "--tags", "--abbrev=0"])
    
    if last_tag:
        # Get log from last tag to HEAD
        revision_range = f"{last_tag}..HEAD"
    else:
        # If no tags exist, get everything
        revision_range = "HEAD"

    # 2. Get the commit subjects
    # %s = subject
    log_output = run_git_command(["git", "log", revision_range, "--pretty=format:%s"])
    
    if not log_output:
        return []
        
    return log_output.split('\n')

def main():
    commits = get_commit_messages()
    
    # Categories
    fixed_bugs = []
    features = []
    others = []
    
    has_robot_changes = False

    # 3. Categorize
    for msg in commits:
        msg = msg.strip()
        if not msg: 
            continue

        # Check for robot flag (applies globally)
        if ":robot:" in msg:
            has_robot_changes = True

        # Clean the message by removing all :emoji: patterns
        clean_msg = re.sub(r':[a-zA-Z0-9_+-]+:', '', msg).strip()

        # Bucket sorting
        if ":bug:" in msg:
            fixed_bugs.insert(0, clean_msg)
        elif ":sparkles:" in msg or ":children_crossing:" in msg:
            features.insert(0, clean_msg)
        else:
            others.insert(0, clean_msg)

    # 4. Construct Output
    output_lines = []

    if features:
        output_lines.append("### New features and improvements")
        for msg in features:
            output_lines.append(f"- {msg}")
        output_lines.append("") # Empty line for spacing

    if fixed_bugs:
        output_lines.append("### Fixed bugs")
        for msg in fixed_bugs:
            output_lines.append(f"- {msg}")
        output_lines.append("")

    if others:
        output_lines.append("### Other")
        for msg in others:
            output_lines.append(f"- {msg}")
        output_lines.append("")

    if has_robot_changes:
        if output_lines and output_lines[-1] == "":
             output_lines.pop()
        output_lines.append("---")
        output_lines.append("_Changes made with the help of an LLM_")

    # Join and print to stdout
    final_output = "\n".join(output_lines).strip()
    print(final_output)

    # Write to GITHUB_STEP_SUMMARY if running in Actions
    if "GITHUB_STEP_SUMMARY" in os.environ:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(final_output + "\n")

if __name__ == "__main__":
    main()
