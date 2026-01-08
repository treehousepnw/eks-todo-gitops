"""
TODO API - A simple REST API for managing todo items.

This Flask application provides CRUD operations for todo items stored in PostgreSQL.
It's designed to run in a Kubernetes environment with the following features:

- Connection pooling for efficient database access
- Health check endpoint for Kubernetes probes
- Structured logging for observability
- CORS support for web clients
- Automatic schema initialization

Environment Variables:
    DB_HOST: PostgreSQL host (default: localhost)
    DB_PORT: PostgreSQL port (default: 5432)
    DB_NAME: Database name (default: tododb)
    DB_USER: Database username (default: todoadmin)
    DB_PASSWORD: Database password (required in production)
    PORT: Server port (default: 8080)
    ENVIRONMENT: Environment name for logging (default: dev)

Example:
    $ export DB_HOST=localhost DB_PASSWORD=secret
    $ python app.py
    # Or with gunicorn:
    $ gunicorn -w 2 -b 0.0.0.0:8080 app:app
"""

from flask import Flask, jsonify, request
from flask_cors import CORS
import os
import logging
import psycopg2
from psycopg2.extras import RealDictCursor
from psycopg2.pool import SimpleConnectionPool

app = Flask(__name__)
CORS(app)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Database configuration from environment
DB_CONFIG = {
    'host': os.getenv('DB_HOST', 'localhost'),
    'port': int(os.getenv('DB_PORT', 5432)),
    'database': os.getenv('DB_NAME', 'tododb'),
    'user': os.getenv('DB_USER', 'todoadmin'),
    'password': os.getenv('DB_PASSWORD', ''),
}

# Connection pool
db_pool = None


def init_db_pool():
    """
    Initialize the database connection pool.

    Creates a connection pool with 1-10 connections for efficient database access.
    Connection pooling reduces the overhead of creating new connections for each request.

    Raises:
        Exception: If unable to connect to the database. The application will continue
                   running but database operations will fail.

    Side Effects:
        - Sets the global db_pool variable
        - Calls init_schema() to create tables if needed
        - Logs connection status
    """
    global db_pool
    try:
        db_pool = SimpleConnectionPool(
            minconn=1,
            maxconn=10,
            **DB_CONFIG
        )
        logger.info(f"Database pool created: {DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['database']}")

        # Initialize schema
        init_schema()

    except Exception as e:
        logger.error(f"Failed to create database pool: {str(e)}")
        raise


def init_schema():
    """
    Create the todos table if it doesn't exist.

    This function is called during application startup to ensure the database
    schema is ready. It uses IF NOT EXISTS to be idempotent.

    Table Schema:
        - id: Auto-incrementing primary key
        - title: Todo item text (required, max 255 chars)
        - completed: Boolean flag (default: false)
        - created_at: Timestamp of creation
        - updated_at: Timestamp of last update

    Raises:
        Exception: If schema creation fails (e.g., permission issues)
    """
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS todos (
                    id SERIAL PRIMARY KEY,
                    title VARCHAR(255) NOT NULL,
                    completed BOOLEAN DEFAULT FALSE,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
            """)
            conn.commit()
            logger.info("Database schema initialized")
    except Exception as e:
        conn.rollback()
        logger.error(f"Failed to initialize schema: {str(e)}")
        raise
    finally:
        db_pool.putconn(conn)


def get_db_conn():
    """
    Get a connection from the database pool.

    Returns:
        psycopg2.connection: A database connection from the pool.

    Note:
        The caller MUST return the connection using return_db_conn()
        when done to avoid pool exhaustion.

    Example:
        conn = get_db_conn()
        try:
            # use connection
        finally:
            return_db_conn(conn)
    """
    return db_pool.getconn()


def return_db_conn(conn):
    """
    Return a connection to the database pool.

    Args:
        conn: The database connection to return to the pool.

    Note:
        Always call this in a finally block to ensure connections
        are returned even if an exception occurs.
    """
    db_pool.putconn(conn)


# Initialize database pool on startup
try:
    init_db_pool()
except Exception as e:
    logger.error(f"Failed to initialize database: {str(e)}")
    # Continue running for health checks, but database operations will fail


@app.route('/health', methods=['GET'])
def health():
    """
    Health check endpoint for Kubernetes probes.

    This endpoint is used by Kubernetes for:
    - Liveness probes: Restart pod if unhealthy
    - Readiness probes: Remove from service if not ready

    Returns:
        tuple: JSON response with health status and HTTP status code.
            - 200: Database is healthy
            - 503: Database is unhealthy (degraded mode)

    Response JSON:
        {
            "status": "healthy" | "degraded",
            "environment": "<env name>",
            "version": "2.0.0",
            "storage": "postgresql",
            "database": "healthy" | "unhealthy"
        }
    """
    db_healthy = False
    try:
        conn = get_db_conn()
        with conn.cursor() as cur:
            cur.execute('SELECT 1')
            db_healthy = True
        return_db_conn(conn)
    except Exception as e:
        logger.error(f"Database health check failed: {str(e)}")

    return jsonify({
        'status': 'healthy' if db_healthy else 'degraded',
        'environment': os.getenv('ENVIRONMENT', 'dev'),
        'version': '2.0.0',
        'storage': 'postgresql',
        'database': 'healthy' if db_healthy else 'unhealthy'
    }), 200 if db_healthy else 503


@app.route('/api/todos', methods=['GET'])
def get_todos():
    """
    Get all todo items.

    Returns all todos ordered by ID (oldest first).

    Returns:
        tuple: JSON array of todos and HTTP status code.
            - 200: Success with array of todos
            - 500: Database error

    Response JSON (200):
        [
            {
                "id": 1,
                "title": "Buy groceries",
                "completed": false,
                "created_at": "2024-01-15T10:30:00",
                "updated_at": "2024-01-15T10:30:00"
            },
            ...
        ]
    """
    conn = get_db_conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute('SELECT id, title, completed, created_at, updated_at FROM todos ORDER BY id')
            todos = cur.fetchall()
            logger.info(f"Retrieved {len(todos)} todos")
            return jsonify(todos), 200
    except Exception as e:
        logger.error(f"Error fetching todos: {str(e)}")
        return jsonify({'error': 'Database error'}), 500
    finally:
        return_db_conn(conn)


@app.route('/api/todos', methods=['POST'])
def create_todo():
    """
    Create a new todo item.

    Request JSON:
        {
            "title": "Buy groceries",      # Required
            "completed": false             # Optional, default: false
        }

    Returns:
        tuple: JSON of created todo and HTTP status code.
            - 201: Successfully created
            - 400: Missing required field (title)
            - 500: Database error

    Response JSON (201):
        {
            "id": 1,
            "title": "Buy groceries",
            "completed": false,
            "created_at": "2024-01-15T10:30:00",
            "updated_at": "2024-01-15T10:30:00"
        }
    """
    data = request.get_json()

    if not data or 'title' not in data:
        return jsonify({'error': 'Title is required'}), 400

    conn = get_db_conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                'INSERT INTO todos (title, completed) VALUES (%s, %s) RETURNING id, title, completed, created_at, updated_at',
                (data['title'], data.get('completed', False))
            )
            todo = cur.fetchone()
            conn.commit()
            logger.info(f"Created todo: {todo['title']}")
            return jsonify(todo), 201
    except Exception as e:
        conn.rollback()
        logger.error(f"Error creating todo: {str(e)}")
        return jsonify({'error': 'Database error'}), 500
    finally:
        return_db_conn(conn)


@app.route('/api/todos/<int:todo_id>', methods=['GET'])
def get_todo(todo_id):
    """
    Get a specific todo item by ID.

    Args:
        todo_id: The unique identifier of the todo item.

    Returns:
        tuple: JSON of todo and HTTP status code.
            - 200: Success
            - 404: Todo not found
            - 500: Database error

    Response JSON (200):
        {
            "id": 1,
            "title": "Buy groceries",
            "completed": false,
            "created_at": "2024-01-15T10:30:00",
            "updated_at": "2024-01-15T10:30:00"
        }
    """
    conn = get_db_conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute('SELECT id, title, completed, created_at, updated_at FROM todos WHERE id = %s', (todo_id,))
            todo = cur.fetchone()
            if not todo:
                return jsonify({'error': 'Todo not found'}), 404
            return jsonify(todo), 200
    except Exception as e:
        logger.error(f"Error fetching todo {todo_id}: {str(e)}")
        return jsonify({'error': 'Database error'}), 500
    finally:
        return_db_conn(conn)


@app.route('/api/todos/<int:todo_id>', methods=['PUT'])
def update_todo(todo_id):
    """
    Update an existing todo item.

    Supports partial updates - only fields provided will be updated.
    The updated_at timestamp is automatically set to the current time.

    Args:
        todo_id: The unique identifier of the todo to update.

    Request JSON:
        {
            "title": "Updated title",    # Optional
            "completed": true            # Optional
        }

    Returns:
        tuple: JSON of updated todo and HTTP status code.
            - 200: Successfully updated
            - 404: Todo not found
            - 500: Database error

    Response JSON (200):
        {
            "id": 1,
            "title": "Updated title",
            "completed": true,
            "created_at": "2024-01-15T10:30:00",
            "updated_at": "2024-01-15T11:00:00"
        }
    """
    data = request.get_json()

    conn = get_db_conn()
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            # Check if todo exists
            cur.execute('SELECT id FROM todos WHERE id = %s', (todo_id,))
            if not cur.fetchone():
                return jsonify({'error': 'Todo not found'}), 404

            # Build update query dynamically based on provided fields
            updates = []
            params = []
            if 'title' in data:
                updates.append('title = %s')
                params.append(data['title'])
            if 'completed' in data:
                updates.append('completed = %s')
                params.append(data['completed'])

            updates.append('updated_at = CURRENT_TIMESTAMP')
            params.append(todo_id)

            query = f"UPDATE todos SET {', '.join(updates)} WHERE id = %s RETURNING id, title, completed, created_at, updated_at"
            cur.execute(query, params)
            todo = cur.fetchone()
            conn.commit()

            logger.info(f"Updated todo {todo_id}")
            return jsonify(todo), 200
    except Exception as e:
        conn.rollback()
        logger.error(f"Error updating todo {todo_id}: {str(e)}")
        return jsonify({'error': 'Database error'}), 500
    finally:
        return_db_conn(conn)


@app.route('/api/todos/<int:todo_id>', methods=['DELETE'])
def delete_todo(todo_id):
    """
    Delete a todo item.

    Args:
        todo_id: The unique identifier of the todo to delete.

    Returns:
        tuple: Empty response and HTTP status code.
            - 204: Successfully deleted (no content)
            - 404: Todo not found
            - 500: Database error
    """
    conn = get_db_conn()
    try:
        with conn.cursor() as cur:
            cur.execute('DELETE FROM todos WHERE id = %s RETURNING id', (todo_id,))
            deleted = cur.fetchone()
            if not deleted:
                return jsonify({'error': 'Todo not found'}), 404
            conn.commit()
            logger.info(f"Deleted todo {todo_id}")
            return '', 204
    except Exception as e:
        conn.rollback()
        logger.error(f"Error deleting todo {todo_id}: {str(e)}")
        return jsonify({'error': 'Database error'}), 500
    finally:
        return_db_conn(conn)


if __name__ == '__main__':
    port = int(os.getenv('PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=False)
