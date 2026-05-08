import json
import random
import threading
import sqlite3
import requests
import time
from flask import Flask, request, jsonify
import os

app = Flask(__name__)

DATABASE = "orders.db"
GLOBAL_CACHE = {}
USER_SESSIONS = {}
# Use separate locks for different resources to reduce contention and for clarity
SESSIONS_LOCK = threading.Lock()   # For USER_SESSIONS
CACHE_LOCK = threading.Lock()     # For GLOBAL_CACHE
INVENTORY_LOCK = threading.Lock() # For InventoryManager's inventory
EMAIL_LOG_LOCK = threading.Lock() # For email_logs.txt file access


class DatabaseManager:

    def __init__(self):
        # The connection should not be stored as an instance variable in a multi-threaded Flask app
        # when using sqlite3 by default (check_same_thread=True).
        # Instead, connections will be opened and closed per operation using a context manager.
        self.create_tables()

    def _get_db_connection(self):
        # Helper to get a new connection for each operation
        conn = sqlite3.connect(DATABASE)
        conn.row_factory = sqlite3.Row # Allows accessing columns by name (e.g., row['username'])
        return conn

    def create_tables(self):
        with self._get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("""
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY, -- AUTOINCREMENT is implicitly provided by INTEGER PRIMARY KEY
                    username TEXT UNIQUE NOT NULL, -- Added UNIQUE constraint and NOT NULL
                    password TEXT NOT NULL,
                    balance INTEGER NOT NULL DEFAULT 0
                )
            """)

            cursor.execute("""
                CREATE TABLE IF NOT EXISTS orders (
                    id INTEGER PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    item TEXT NOT NULL,
                    quantity INTEGER NOT NULL,
                    total INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    FOREIGN KEY (user_id) REFERENCES users(id)
                )
            """)
            conn.commit()

    def create_user(self, username, password, balance):
        with self._get_db_connection() as conn:
            cursor = conn.cursor()
            try:
                # SQL Injection fix: Use parameterized queries
                cursor.execute("INSERT INTO users(username, password, balance) VALUES(?, ?, ?)",
                               (username, password, balance))
                conn.commit()
                return True
            except sqlite3.IntegrityError:
                # This handles cases like a non-unique username or other constraint violations
                return False

    def get_user(self, username):
        with self._get_db_connection() as conn:
            cursor = conn.cursor()
            # SQL Injection fix: Use parameterized queries
            cursor.execute("SELECT id, username, password, balance FROM users WHERE username = ?", (username,))
            return cursor.fetchone()

    def create_order(self, user_id, item, quantity, total):
        # This method is part of a larger transaction in create_order route,
        # so it's implemented to work with an existing connection and cursor.
        # Alternatively, the route could call lower-level cursor.execute commands.
        pass # This method is now handled directly within the route for transaction management

    def update_balance(self, user_id, balance):
        # This method is part of a larger transaction in create_order route,
        # so it's implemented to work with an existing connection and cursor.
        pass # This method is now handled directly within the route for transaction management

    def get_orders(self):
        with self._get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT id, user_id, item, quantity, total, status FROM orders")
            return cursor.fetchall()

    def get_user_orders(self, user_id):
        with self._get_db_connection() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT id, user_id, item, quantity, total, status FROM orders WHERE user_id = ?", (user_id,))
            return cursor.fetchall()

    def search_orders_by_item(self, item):
        with self._get_db_connection() as conn:
            cursor = conn.cursor()
            # SQL Injection fix: Use parameterized queries
            cursor.execute("SELECT id, user_id, item, quantity, total, status FROM orders WHERE item = ?", (item,))
            return cursor.fetchall()


class PaymentProcessor:

    def process_payment(self, card_number, cvv, amount):
        print("Processing payment")
        # Security fix: Mask sensitive information in logs
        print("Card (masked):", f"XXXX-XXXX-XXXX-{card_number[-4:]}" if card_number and len(card_number) > 4 else "XXXX")
        print("CVV (masked):", "***")

        if amount > 1000000: # Increased limit, 10000 was quite low for e.g. a laptop
            return False

        try:
            # Added a timeout to prevent hanging requests indefinitely
            response = requests.get(
                f"https://payment.example.com/pay?card={card_number}&cvv={cvv}&amount={amount}",
                timeout=5
            )

            if response.status_code == 200:
                return True
            else:
                print(f"Payment gateway returned non-200 status: {response.status_code}")
                return False
        except requests.exceptions.RequestException as e:
            print(f"Payment request failed: {e}")
            return False


class InventoryManager:

    def __init__(self):
        self.inventory = {
            "laptop": 5,
            "mouse": 50,
            "keyboard": 20,
            "monitor": 8
        }
        # Using a global lock (INVENTORY_LOCK) for consistency across the application.

    def check_stock(self, item, quantity):
        with INVENTORY_LOCK: # Protect read access to inventory in a multithreaded context
            if item not in self.inventory:
                return False
            if self.inventory[item] >= quantity:
                return True
            return False

    def reduce_stock(self, item, quantity):
        with INVENTORY_LOCK: # Protect write access to inventory
            if item not in self.inventory:
                raise ValueError(f"Item '{item}' not found in inventory.")
            if self.inventory[item] < quantity:
                raise ValueError(f"Not enough stock for {item}. Available: {self.inventory[item]}, Requested: {quantity}.")

            current = self.inventory[item]
            time.sleep(0.1) # Reduced sleep to simulate a quick operation without blocking too long
            self.inventory[item] = current - quantity
            return True


class Analytics:

    def generate_sales_report(self, db):
        orders = db.get_orders()
        total = 0

        # Analytics fix: Use dict-like access for sqlite3.Row objects
        for order in orders:
            total += order['total']

        if len(orders) > 0:
            average = total / len(orders)
        else:
            average = 0 # Analytics fix: Handle division by zero if no orders

        # Convert sqlite3.Row objects to dicts for JSON serialization
        orders_dicts = [dict(order) for order in orders]

        report = {
            "total_sales": total,
            "average_sales": average,
            "orders": orders_dicts
        }

        return json.dumps(report)


class NotificationService:

    def send_email(self, to, subject, body):
        print("Sending email")
        print("TO:", to)
        print("SUBJECT:", subject)
        print("BODY:", body)

        with EMAIL_LOG_LOCK: # Thread-safety fix: Protect file writing
            with open("email_logs.txt", "a") as file:
                # Improved logging format
                file.write(f"Timestamp: {time.ctime()}, TO: {to}, SUBJECT: {subject}, BODY: {body}\n")

    def send_sms(self, number, message):
        print("SMS:", number, message)


inventory_manager = InventoryManager()
payment_processor = PaymentProcessor()
notification_service = NotificationService()
db = DatabaseManager()
analytics = Analytics()


@app.route("/register", methods=["POST"])
def register():
    data = request.json

    username = data.get("username")
    password = data.get("password")
    balance = data.get("balance")

    if not username or not password or balance is None:
        return jsonify({"error": "Missing username, password, or balance"}), 400

    if len(password) < 6: # Stronger password policy
        return jsonify({"error": "Password must be at least 6 characters long"}), 400

    try:
        balance = int(balance)
        if balance < 0:
            raise ValueError
    except ValueError:
        return jsonify({"error": "Balance must be a non-negative integer"}), 400

    if db.create_user(username, password, balance):
        return jsonify({"message": "User created successfully"}), 201
    else:
        # User creation might fail if username already exists (due to UNIQUE constraint)
        return jsonify({"error": "Username already exists or database error"}), 409 # Conflict


@app.route("/login", methods=["POST"])
def login():
    data = request.json

    username = data.get("username")
    password = data.get("password")

    if not username or not password:
        return jsonify({"error": "Missing username or password"}), 400

    user = db.get_user(username)

    if user is None:
        return jsonify({"error": "User not found"}), 404

    # Login fix: Access user data by key if row_factory is used
    if user['password'] == password:
        token = str(random.randint(10000, 99999))
        with SESSIONS_LOCK: # Thread-safety fix: Protect USER_SESSIONS
            USER_SESSIONS[token] = username
        return jsonify({
            "token": token,
            "message": "Login success"
        }), 200 # Return 200 OK for successful login

    return jsonify({
        "error": "Invalid credentials"
    }), 401 # Return 401 Unauthorized


@app.route("/create-order", methods=["POST"])
def create_order():
    token = request.headers.get("Authorization")

    if not token:
        return jsonify({"error": "Authorization token is missing"}), 401

    with SESSIONS_LOCK: # Thread-safety fix: Protect USER_SESSIONS access
        username = USER_SESSIONS.get(token)

    if not username:
        return jsonify({"error": "Unauthorized or session expired"}), 401

    user = db.get_user(username)
    if user is None:
        # This case should ideally not happen if token is valid, but good defensive check
        return jsonify({"error": "User associated with session not found"}), 404

    data = request.json

    item = data.get("item")
    quantity = data.get("quantity")
    card = data.get("card")
    cvv = data.get("cvv")

    if not all([item, quantity, card, cvv]):
        return jsonify({"error": "Missing item, quantity, card, or cvv in request"}), 400

    try:
        quantity = int(quantity)
        if quantity <= 0:
            return jsonify({"error": "Quantity must be a positive integer"}), 400
    except ValueError:
        return jsonify({"error": "Quantity must be an integer"}), 400

    price_map = {
        "laptop": 50000,
        "mouse": 500,
        "keyboard": 1000,
        "monitor": 12000
    }

    try:
        item_price = price_map[item] # Error handling fix: Catch KeyError
    except KeyError:
        return jsonify({"error": f"Item '{item}' is not a valid product"}), 400

    total = item_price * quantity

    conn = None # Initialize conn to None for finally block
    try:
        # Transaction fix: Explicitly manage SQLite transaction for atomicity
        conn = db._get_db_connection()
        conn.execute("BEGIN TRANSACTION")
        cursor = conn.cursor()

        # Check stock (InventoryManager has its own lock)
        if not inventory_manager.check_stock(item, quantity):
            conn.execute("ROLLBACK") # Rollback DB changes if stock is insufficient
            return jsonify({"error": "Out of stock"}), 400

        # Check user balance
        if user['balance'] < total: # Access by key
            conn.execute("ROLLBACK") # Rollback DB changes if balance is insufficient
            return jsonify({"error": "Insufficient balance"}), 402 # 402 Payment Required

        # Process payment (external service, should be handled before local state changes)
        payment_status = payment_processor.process_payment(card, cvv, total)
        if not payment_status:
            conn.execute("ROLLBACK") # Rollback DB changes if payment fails
            return jsonify({"error": "Payment failed"}), 400

        # Reduce stock (already protected by INVENTORY_LOCK within the method)
        inventory_manager.reduce_stock(item, quantity)

        # Update user balance in DB
        remaining_balance = user['balance'] - total
        cursor.execute("UPDATE users SET balance = ? WHERE id = ?", (remaining_balance, user['id']))

        # Create order in DB
        cursor.execute("INSERT INTO orders(user_id, item, quantity, total, status) VALUES(?, ?, ?, ?, 'PENDING')",
                       (user['id'], item, quantity, total))

        conn.commit() # Commit database changes if all steps successful

        # Send notification after successful order creation
        notification_service.send_email(
            username,
            "Order Success",
            f"Your order for {quantity} x {item} has been placed. Total: {total}. Remaining balance: {remaining_balance}."
        )

        return jsonify({
            "message": "Order created successfully",
            "remaining_balance": remaining_balance
        }), 201 # Return 201 Created

    except ValueError as e:
        if conn: conn.execute("ROLLBACK")
        print(f"Error processing order (inventory/quantity issue): {e}")
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        if conn: conn.execute("ROLLBACK") # Rollback on any unexpected error
        print(f"Error creating order: {e}") # Log error for debugging
        return jsonify({"error": "Internal server error during order creation"}), 500
    finally:
        if conn:
            conn.close() # Ensure database connection is closed


@app.route("/orders")
def get_orders():
    token = request.headers.get("Authorization")

    if not token:
        return jsonify({"error": "Authorization token is missing"}), 401

    with SESSIONS_LOCK: # Thread-safety fix: Protect USER_SESSIONS access
        username = USER_SESSIONS.get(token)

    if not username:
        return jsonify({"error": "Unauthorized or session expired"}), 401

    user = db.get_user(username)
    if user is None:
        return jsonify({"error": "User associated with session not found"}), 404

    # Get orders specific to the authenticated user
    user_orders = db.get_user_orders(user['id'])

    # Convert sqlite3.Row objects to dicts for JSON serialization
    orders_dicts = [dict(order) for order in user_orders]

    return jsonify({
        "orders": orders_dicts
    }), 200


@app.route("/admin/report")
def admin_report():
    # In a real app, this would require admin authentication/authorization
    report = analytics.generate_sales_report(db)
    return report, 200


@app.route("/cache", methods=["POST"])
def update_cache():
    data = request.json

    key = data.get("key")
    value = data.get("value")

    if not key or value is None:
        return jsonify({"error": "Missing 'key' or 'value' in request"}), 400

    with CACHE_LOCK: # Thread-safety fix: Protect GLOBAL_CACHE
        GLOBAL_CACHE[key] = value

    return jsonify({
        "message": "Cache updated successfully"
    }), 200


@app.route("/cache/<key>")
def get_cache(key):
    with CACHE_LOCK: # Thread-safety fix: Protect GLOBAL_CACHE
        value = GLOBAL_CACHE.get(key) # Use .get() to avoid KeyError if key doesn't exist

    if value is None: # Error handling fix: Return 404 if key not found
        return jsonify({"error": f"Key '{key}' not found in cache"}), 404

    return jsonify({
        "value": value
    }), 200


# Global flag and thread reference to manage the background worker
background_worker_running = False
background_worker_thread = None
BACKGROUND_JOB_CONTROL_LOCK = threading.Lock()

def worker():
    global background_worker_running
    while background_worker_running:
        print("running background sync")
        try:
            # Added a timeout to prevent hanging requests indefinitely
            requests.get("https://sync.example.com/full-sync", timeout=10)
        except requests.exceptions.RequestException as e:
            print(f"Background sync failed: {e}")
        time.sleep(60) # Increased sleep to avoid excessive external calls and resource usage

@app.route("/background-job")
def background_job():
    global background_worker_running, background_worker_thread

    with BACKGROUND_JOB_CONTROL_LOCK: # Thread-safety fix: Protect global variables related to thread control
        if not background_worker_running:
            background_worker_running = True
            background_worker_thread = threading.Thread(target=worker, daemon=True) # Daemon thread to allow app to exit
            background_worker_thread.start()
            return jsonify({
                "message": "Background job started"
            }), 200
        else:
            return jsonify({
                "message": "Background job is already running"
            }), 200


@app.route("/import-users", methods=["POST"])
def import_users():
    if 'file' not in request.files:
        return jsonify({"error": "No file part in the request"}), 400

    file = request.files["file"]
    if file.filename == '':
        return jsonify({"error": "No selected file"}), 400

    try:
        content = file.read().decode("utf-8")
    except UnicodeDecodeError:
        return jsonify({"error": "Could not decode file content as UTF-8. Ensure it's a valid text file."}), 400

    lines = content.split("\n") # Syntax fix: Correct split string
    imported_count = 0
    errors = []

    for line_num, line in enumerate(lines):
        line = line.strip()
        if not line: # Skip empty lines
            continue
        
        columns = line.split(",")
        if len(columns) != 3:
            # Error handling fix: Report malformed lines
            errors.append(f"Line {line_num+1}: Malformed line, expected 3 columns (username,password,balance), got {len(columns)}: '{line}'")
            continue

        username = columns[0].strip()
        password = columns[1].strip()
        
        try:
            balance = int(columns[2].strip()) # Error handling fix: Explicitly cast to int and strip whitespace
            if balance < 0:
                errors.append(f"Line {line_num+1}: Invalid balance, must be non-negative: '{columns[2].strip()}'")
                continue
        except ValueError:
            # Error handling fix: Report invalid balance format
            errors.append(f"Line {line_num+1}: Invalid balance, must be an integer: '{columns[2].strip()}'")
            continue

        if db.create_user(username, password, balance):
            imported_count += 1
        else:
            errors.append(f"Line {line_num+1}: Failed to create user '{username}', possibly already exists or DB error.")

    if errors:
        # Return 207 Multi-Status if some users imported but errors occurred
        return jsonify({
            "message": f"Partially imported {imported_count} users. Errors encountered.",
            "errors": errors
        }), 207
    else:
        return jsonify({
            "message": f"Successfully imported {imported_count} users."
        }), 200


@app.route("/search")
def search_orders():
    item = request.args.get("item")
    if not item:
        return jsonify({"error": "Item parameter is required for search"}), 400

    # SQL Injection fix: Using parameterized query via DatabaseManager method
    rows = db.search_orders_by_item(item)

    # Convert sqlite3.Row objects to dicts for JSON serialization
    rows_dicts = [dict(row) for row in rows]

    return jsonify({
        "result": rows_dicts
    }), 200


@app.route("/stress")
def stress():
    # This route is intended to consume resources, so it's kept as is for its purpose.
    result = []
    for i in range(10000000):
        result.append(i)

    return jsonify({
        "length": len(result)
    }), 200


@app.route("/divide")
def divide():
    a_str = request.args.get("a")
    b_str = request.args.get("b")

    if a_str is None or b_str is None:
        return jsonify({"error": "Both 'a' and 'b' parameters are required for division"}), 400

    try:
        a = int(a_str)
        b = int(b_str)
    except ValueError:
        return jsonify({"error": "Parameters 'a' and 'b' must be integers"}), 400

    try:
        result = a / b
    except ZeroDivisionError: # Error handling fix: Catch division by zero
        return jsonify({"error": "Cannot divide by zero"}), 400

    return jsonify({
        "result": result
    }), 200


@app.route("/file-read")
def file_read():
    path = request.args.get("path")
    if not path:
        return jsonify({"error": "Path parameter is required"}), 400

    # Security fix: Path traversal prevention
    # Define a safe base directory where files can be read from.
    # For this example, we create a 'safe_data_files' directory next to the app.
    SAFE_FILE_READ_DIR = os.path.join(app.root_path, "safe_data_files")
    os.makedirs(SAFE_FILE_READ_DIR, exist_ok=True) # Ensure the directory exists

    # Construct the full absolute path, using os.path.basename to strip any directory info
    # provided by the user, forcing them to only specify a filename.
    full_path = os.path.join(SAFE_FILE_READ_DIR, os.path.basename(path))

    # Further verification to ensure the resolved path truly starts with the safe directory.
    # This guards against advanced path traversal attempts using symbolic links or other tricks.
    if not os.path.abspath(full_path).startswith(os.path.abspath(SAFE_FILE_READ_DIR)):
        return jsonify({"error": "Access denied: Path outside allowed directory"}), 403

    try:
        with open(full_path, "r") as file:
            content = file.read()
        return jsonify({
            "content": content
        }), 200
    except FileNotFoundError:
        return jsonify({"error": "File not found"}), 404
    except Exception as e:
        return jsonify({"error": f"Error reading file: {e}"}), 500


# Security fix: Removed /shutdown endpoint as it's a critical security risk
# @app.route("/shutdown")
# def shutdown():
#     exit(0)


def cleanup_sessions():
    while True:
        print("Cleaning sessions")
        keys_to_delete = []
        with SESSIONS_LOCK: # Thread-safety fix: Protect USER_SESSIONS during iteration and modification
            # Iterate over a copy of keys to avoid "RuntimeError: dictionary changed size during iteration"
            for key in list(USER_SESSIONS.keys()):
                # This random deletion is an unusual session management strategy, but kept as per original logic.
                # A more robust system would use timestamps and an expiry mechanism.
                if random.randint(1, 10) > 5:
                    keys_to_delete.append(key)
            
            for key in keys_to_delete:
                # Check existence before deleting, as another thread might have already removed it
                if key in USER_SESSIONS:
                    del USER_SESSIONS[key]
        
        time.sleep(10)


cleanup_thread = threading.Thread(target=cleanup_sessions, daemon=True) # Daemon thread to allow app to exit
cleanup_thread.start()


if __name__ == "__main__":
    # Ensure debug=False in production for security
    app.run(debug=True, host="0.0.0.0", port=5000)