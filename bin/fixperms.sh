#!/bin/bash

# fixperms.sh - Fix web directory permissions for UserSpice/web apps
# Usage: ./fixperms.sh [directory_name|*]
# Example: ./fixperms.sh plgdev
# Example: ./fixperms.sh *

# Configuration - adjust these if needed
WEB_ROOT="/var/www/html"
WEB_USER="www-data"
WEB_GROUP="webdev"
CURRENT_USER=$(whoami)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to fix permissions for a single directory
fix_directory_perms() {
    local target_dir="$1"
    local full_path="$WEB_ROOT/$target_dir"
    
    if [ ! -d "$full_path" ]; then
        print_error "Directory $full_path does not exist"
        return 1
    fi
    
    print_status "Fixing permissions for: $full_path"
    
    # Set ownership to current user and webdev group
    print_status "Setting ownership to $CURRENT_USER:$WEB_GROUP"
    sudo chown -R "$CURRENT_USER:$WEB_GROUP" "$full_path"
    
    # Set directory permissions (755 + group write = 775)
    print_status "Setting directory permissions to 775"
    sudo find "$full_path" -type d -exec chmod 775 {} \;
    
    # Set file permissions (644 + group write = 664)
    print_status "Setting file permissions to 664"
    sudo find "$full_path" -type f -exec chmod 664 {} \;
    
    # Make PHP files executable
    print_status "Making PHP files executable"
    sudo find "$full_path" -name "*.php" -exec chmod 775 {} \;
    
    # Set the setgid bit on directories so new files inherit the group
    print_status "Setting setgid bit on directories"
    sudo find "$full_path" -type d -exec chmod g+s {} \;
    
    print_status "Completed: $target_dir"
    echo ""
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Don't run this script as root. Run as your regular user - it will use sudo when needed."
    exit 1
fi

# Check if webdev group exists
if ! getent group "$WEB_GROUP" > /dev/null 2>&1; then
    print_error "Group '$WEB_GROUP' does not exist. Please create it first:"
    echo "  sudo groupadd $WEB_GROUP"
    echo "  sudo usermod -a -G $WEB_GROUP $CURRENT_USER"
    echo "  sudo usermod -a -G $WEB_GROUP $WEB_USER"
    exit 1
fi

# Check if user is in webdev group
if ! groups "$CURRENT_USER" | grep -q "$WEB_GROUP"; then
    print_error "User '$CURRENT_USER' is not in group '$WEB_GROUP'"
    echo "Run: sudo usermod -a -G $WEB_GROUP $CURRENT_USER"
    echo "Then log out and back in."
    exit 1
fi

# Check if www-data is in webdev group  
if ! groups "$WEB_USER" | grep -q "$WEB_GROUP"; then
    print_error "User '$WEB_USER' is not in group '$WEB_GROUP'"
    echo "Run: sudo usermod -a -G $WEB_GROUP $WEB_USER"
    exit 1
fi

# Main logic
if [ $# -eq 0 ]; then
    print_error "Usage: $0 [directory_name|*]"
    echo "Examples:"
    echo "  $0 plgdev"
    echo "  $0 '*'"
    exit 1
fi

cd "$WEB_ROOT" || exit 1

if [ "$1" = "*" ]; then
    print_status "Fixing permissions for ALL directories in $WEB_ROOT"
    print_warning "This will take a while..."
    
    for dir in */; do
        if [ -d "$dir" ]; then
            fix_directory_perms "${dir%/}"
        fi
    done
else
    fix_directory_perms "$1"
fi

print_status "Permission fixing complete!"
print_status "Both you ($CURRENT_USER) and the web server ($WEB_USER) should now have full access."

# Test if we can create a file as www-data
if [ "$1" != "*" ]; then
    test_file="$WEB_ROOT/$1/perm_test_$(date +%s).tmp"
    if sudo -u "$WEB_USER" touch "$test_file" 2>/dev/null; then
        sudo rm "$test_file"
        print_status "✓ Permission test passed - www-data can write to $1"
    else
        print_error "✗ Permission test failed - www-data cannot write to $1"
    fi
fi
```
