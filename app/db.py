import psycopg2
import os
import logging

logger = logging.getLogger(__name__)

def get_db_connection():
    """Create database connection from environment variables"""
    conn = psycopg2.connect(
        host=os.getenv('DB_HOST'),
        database=os.getenv('DB_NAME'),
        user=os.getenv('DB_USER'),
        password=os.getenv('DB_PASSWORD'),
        port=os.getenv('DB_PORT', '5432')
    )
    with conn.cursor() as cur:
        cur.execute('SET search_path TO todos;')
    return conn

def init_db():
    """Initialize database schema and table if it doesn't exist"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()

        # Ensure the 'todos' schema exists
        cur.execute('CREATE SCHEMA IF NOT EXISTS todos;')

        # Make sure all future operations use the 'todos' schema by default
        cur.execute('SET search_path TO todos;')

        # Create the todos table inside the 'todos' schema
        cur.execute('''
            CREATE TABLE IF NOT EXISTS todos.todos (
                id SERIAL PRIMARY KEY,
                title VARCHAR(255) NOT NULL,
                completed BOOLEAN DEFAULT FALSE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        ''')

        conn.commit()
        cur.close()
        conn.close()
        logger.info("Database initialized successfully in 'todos' schema")
    except Exception as e:
        logger.error(f"Database initialization failed: {str(e)}")
        raise
