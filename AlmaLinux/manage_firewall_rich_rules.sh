#!/bin/bash
# Manage firewall rich rules - list, inspect, and add new port rules

set -euo pipefail

# Ensure running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root or with sudo."
    exit 1
fi

echo "=========================================="
echo "  Firewall Rich Rules Manager"
echo "=========================================="
echo ""

# Fetch current rich rules
RICH_RULES=$(firewall-cmd --list-rich-rules 2>/dev/null)

if [[ -z "$RICH_RULES" ]]; then
    echo "No rich rules found in the current zone."
    echo ""
    read -p "Enter a source address to create the first rule: " SRC_ADDR
    if [[ -z "$SRC_ADDR" ]]; then
        echo "No address provided. Exiting."
        exit 1
    fi
    read -p "Enter port number to allow for $SRC_ADDR: " NEW_PORT
    if [[ -z "$NEW_PORT" ]] || ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1 || NEW_PORT > 65535 )); then
        echo "Invalid port number. Exiting."
        exit 1
    fi
    firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$SRC_ADDR\" port port=\"$NEW_PORT\" protocol=\"tcp\" accept"
    firewall-cmd --reload
    echo "Added rule: $SRC_ADDR -> port $NEW_PORT/tcp"
    exit 0
fi

# ---- Extract unique source addresses and global max port ----
mapfile -t ADDRESSES < <(echo "$RICH_RULES" | grep -oP 'source address="\K[^"]+' | sort -u)
mapfile -t ALL_PORTS < <(echo "$RICH_RULES" | grep -oP 'port port="\K[^"]+' | sort -n)
GLOBAL_MAX_PORT=${ALL_PORTS[-1]}

echo "Current rich rules by source address:"
echo "------------------------------------------"

for addr in "${ADDRESSES[@]}"; do
    # Get all ports for this address, sort numerically
    mapfile -t PORTS < <(echo "$RICH_RULES" | grep "source address=\"$addr\"" | grep -oP 'port port="\K[^"]+' | sort -n)
    echo "  Source: $addr"
    echo "  Ports : ${PORTS[*]}"
    echo "------------------------------------------"
done

echo "Global maximum port across all addresses: $GLOBAL_MAX_PORT"
echo ""

# ---- Choose source address ----
echo "Select a source address:"
for i in "${!ADDRESSES[@]}"; do
    echo "  $((i + 1))) ${ADDRESSES[$i]}"
done
echo "  $((${#ADDRESSES[@]} + 1))) Enter a new address"
echo ""

while true; do
    read -p "Choice [1-$((${#ADDRESSES[@]} + 1))]: " ADDR_CHOICE
    if [[ "$ADDR_CHOICE" =~ ^[0-9]+$ ]] && (( ADDR_CHOICE >= 1 && ADDR_CHOICE <= ${#ADDRESSES[@]} + 1 )); then
        break
    fi
    echo "Invalid choice. Try again."
done

if (( ADDR_CHOICE <= ${#ADDRESSES[@]} )); then
    SRC_ADDR="${ADDRESSES[$((ADDR_CHOICE - 1))]}"
else
    read -p "Enter new source address (e.g. 10.100.1.3): " SRC_ADDR
    if [[ -z "$SRC_ADDR" ]]; then
        echo "No address provided. Exiting."
        exit 1
    fi
fi

echo ""
echo "Selected source: $SRC_ADDR"

# ---- Get existing ports for the selected address ----
mapfile -t EXISTING_PORTS < <(echo "$RICH_RULES" | grep "source address=\"$SRC_ADDR\"" | grep -oP 'port port="\K[^"]+' | sort -n)

if [[ ${#EXISTING_PORTS[@]} -gt 0 ]]; then
    echo "Existing ports for $SRC_ADDR: ${EXISTING_PORTS[*]}"
else
    echo "No existing ports for this address."
fi

NEXT_PORT=$((GLOBAL_MAX_PORT + 1))
echo "Global max port: $GLOBAL_MAX_PORT  ->  Next auto-increment: $NEXT_PORT"
echo ""

# ---- Choose port ----
echo "How would you like to add a new port?"
echo "  1) Auto-increment (next port: $NEXT_PORT)"
echo "  2) Enter a custom port"
echo ""

while true; do
    read -p "Choice [1-2]: " PORT_CHOICE
    if [[ "$PORT_CHOICE" == "1" || "$PORT_CHOICE" == "2" ]]; then
        break
    fi
    echo "Invalid choice. Try again."
done

if [[ "$PORT_CHOICE" == "1" ]]; then
    NEW_PORT=$NEXT_PORT
else
    read -p "Enter port number: " NEW_PORT
fi

# Validate port
if [[ -z "$NEW_PORT" ]] || ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1 || NEW_PORT > 65535 )); then
    echo "Invalid port number. Exiting."
    exit 1
fi

# Check if the rule already exists
for p in "${EXISTING_PORTS[@]}"; do
    if [[ "$p" == "$NEW_PORT" ]]; then
        echo "Port $NEW_PORT already exists for $SRC_ADDR. Exiting."
        exit 1
    fi
done

echo ""
echo "Adding rich rule: $SRC_ADDR -> port $NEW_PORT/tcp"
read -p "Confirm? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Add the rule
firewall-cmd --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"$SRC_ADDR\" port port=\"$NEW_PORT\" protocol=\"tcp\" accept"
firewall-cmd --reload

echo ""
echo "Rule added and firewall reloaded successfully."
echo ""

# Show updated rules for this address
echo "Updated ports for $SRC_ADDR:"
firewall-cmd --list-rich-rules | grep "source address=\"$SRC_ADDR\"" | grep -oP 'port port="\K[^"]+' | sort -n | tr '\n' ' '
echo ""
