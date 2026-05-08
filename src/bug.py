import json
import random
import threading
import sqlite3
import requests
import time
from flask import Flask, request, jsonify

app = Flask(__name__)

DATABASE = "orders.db"
GLOBAL_CACHE = {}
USER_SESSIONS = {}
LOCK = threading.Lock()


class DatabaseManager:

    def __init__(self):
        self.connection = sqlite3.connect(DATABASE)
        self.cursor = self.connection.cursor()
        self.create_tables()

    def create_tables(self):
        self.cursor.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT,
                password TEXT,
                balance INTEGER
            )
        """)

        self.cursor.execute("""
            CREATE TABLE IF NOT EXISTS orders (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                item TEXT,
                quantity INTEGER,
                total INTEGER,
                status TEXT
            )
        """)

        self.connection.commit()

    def create_user(self, username, password, balance):
        query = f"INSERT INTO users(username,password,balance) VALUES('{username}','{password}',{balance})"
        self.cursor.execute(query)
        self.connection.commit()

    def get_user(self, username):
        query = f"SELECT * FROM users WHERE username = '{username}'"
        result = self.cursor.execute(query)
        return result.fetchone()

    def create_order(self, user_id, item, quantity, total):
        query = f"INSERT INTO orders(user_id,item,quantity,total,status) VALUES({user_id},'{item}',{quantity},{total},'PENDING')"
        self.cursor.execute(query)
        self.connection.commit()

    def get_orders(self):
        result = self.cursor.execute("SELECT * FROM orders")
        return result.fetchall()

    def update_balance(self, user_id, balance):
        query = f"UPDATE users SET balance = {balance} WHERE id = {user_id}"
        self.cursor.execute(query)
        self.connection.commit()


class PaymentProcessor:

    def process_payment(self, card_number, cvv, amount):
        print("Processing payment")
        print("Card:", card_number)
        print("CVV:", cvv)

        if amount > 10000:
            return False

        response = requests.get(
            f"https://payment.example.com/pay?card={card_number}&cvv={cvv}&amount={amount}"
        )

        if response.status_code == 200:
            return True

        return False


class InventoryManager:

    def __init__(self):
        self.inventory = {
            "laptop": 5,
            "mouse": 50,
            "keyboard": 20,
            "monitor": 8
        }

    def check_stock(self, item, quantity):
        if item not in self.inventory:
            return False

        if self.inventory[item] >= quantity:
            return True

        return False

    def reduce_stock(self, item, quantity):
        current = self.inventory[item]
        time.sleep(2)
        self.inventory[item] = current - quantity


class Analytics:

    def generate_sales_report(self, db):
        orders = db.get_orders()
        total = 0

        for order in orders:
            total += order[4]

        average = total / len(orders)

        report = {
            "total_sales": total,
            "average_sales": average,
            "orders": orders
        }

        return json.dumps(report)


class NotificationService:

    def send_email(self, to, subject, body):
        print("Sending email")
        print("TO:", to)
        print("SUBJECT:", subject)
        print("BODY:", body)

        with open("email_logs.txt", "a") as file:
            file.write(to + subject + body)

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

    if len(password) < 3:
        return jsonify({"error": "Weak password"})

    db.create_user(username, password, balance)

    return jsonify({
        "message": "User created"
    })


@app.route("/login", methods=["POST"])
def login():

    data = request.json

    username = data["username"]
    password = data["password"]

    user = db.get_user(username)

    if user == None:
        return jsonify({"error": "User not found"})

    if user[2] == password:
        token = str(random.randint(10000, 99999))
        USER_SESSIONS[token] = username

        return jsonify({
            "token": token,
            "message": "Login success"
        })

    return jsonify({
        "error": "Invalid credentials"
    })


@app.route("/create-order", methods=["POST"])
def create_order():

    token = request.headers.get("Authorization")

    if token not in USER_SESSIONS:
        return jsonify({"error": "Unauthorized"}), 401

    username = USER_SESSIONS[token]

    user = db.get_user(username)

    data = request.json

    item = data["item"]
    quantity = int(data["quantity"])
    card = data["card"]
    cvv = data["cvv"]

    price_map = {
        "laptop": 50000,
        "mouse": 500,
        "keyboard": 1000,
        "monitor": 12000
    }

    total = price_map[item] * quantity

    if inventory_manager.check_stock(item, quantity) == False:
        return jsonify({"error": "Out of stock"})

    if user[3] < total:
        return jsonify({"error": "Insufficient balance"})

    payment_status = payment_processor.process_payment(card, cvv, total)

    if payment_status == False:
        return jsonify({"error": "Payment failed"})

    inventory_manager.reduce_stock(item, quantity)

    remaining_balance = user[3] - total

    db.update_balance(user[0], remaining_balance)

    db.create_order(user[0], item, quantity, total)

    notification_service.send_email(
        username,
        "Order Success",
        f"Order placed for {item}"
    )

    return jsonify({
        "message": "Order created",
        "remaining_balance": remaining_balance
    })


@app.route("/orders")
def get_orders():

    token = request.headers.get("Authorization")

    if token not in USER_SESSIONS:
        return jsonify({"error": "Unauthorized"})

    orders = db.get_orders()

    return jsonify({
        "orders": orders
    })


@app.route("/admin/report")
def admin_report():

    report = analytics.generate_sales_report(db)

    return report


@app.route("/cache", methods=["POST"])
def update_cache():

    data = request.json

    key = data["key"]
    value = data["value"]

    GLOBAL_CACHE[key] = value

    return jsonify({
        "message": "cache updated"
    })


@app.route("/cache/<key>")
def get_cache(key):

    value = GLOBAL_CACHE[key]

    return jsonify({
        "value": value
    })


@app.route("/background-job")
def background_job():

    def worker():
        while True:
            print("running background sync")
            time.sleep(1)
            requests.get("https://sync.example.com/full-sync")

    thread = threading.Thread(target=worker)
    thread.start()

    return jsonify({
        "message": "Background job started"
    })


@app.route("/import-users", methods=["POST"])
def import_users():

    file = request.files["file"]

    content = file.read().decode("utf-8")

    lines = content.split("\n")

    for line in lines:

        columns = line.split(",")

        username = columns[0]
        password = columns[1]
        balance = columns[2]

        db.create_user(username, password, balance)

    return jsonify({
        "message": "users imported"
    })


@app.route("/search")
def search_orders():

    item = request.args.get("item")

    query = f"SELECT * FROM orders WHERE item = '{item}'"

    result = db.cursor.execute(query)

    rows = result.fetchall()

    return jsonify({
        "result": rows
    })


@app.route("/stress")
def stress():

    result = []

    for i in range(10000000):
        result.append(i)

    return jsonify({
        "length": len(result)
    })


@app.route("/divide")
def divide():

    a = int(request.args.get("a"))
    b = int(request.args.get("b"))

    return jsonify({
        "result": a / b
    })


@app.route("/file-read")
def file_read():

    path = request.args.get("path")

    with open(path, "r") as file:
        content = file.read()

    return jsonify({
        "content": content
    })


@app.route("/shutdown")
def shutdown():

    exit(0)


def cleanup_sessions():

    while True:

        print("Cleaning sessions")

        for key in USER_SESSIONS:
            if random.randint(1, 10) > 5:
                del USER_SESSIONS[key]

        time.sleep(10)


cleanup_thread = threading.Thread(target=cleanup_sessions)
cleanup_thread.start()


if __name__ == "__main__":

    app.run(debug=True, host="0.0.0.0", port=5000)
