#!/usr/bin/env python3
import pyodbc
import time
import random
import argparse
import threading
from concurrent.futures import ThreadPoolExecutor

class ComprehensiveSQLServerLoadTest:
    def __init__(self, server, username, password, duration=300):
        self.server = server
        self.username = username
        self.password = password
        self.duration = duration
        self.connection_string = f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={server},1433;DATABASE=master;UID={username};PWD={password};Connection Timeout=30;Login Timeout=30;Encrypt=no"
        self.running = True
        
    def get_connection(self):
        return pyodbc.connect(self.connection_string, timeout=60)
    
    def setup_test_environment(self):
        """Setup test database and tables"""
        print("🔧 Setting up test environment...")
        conn = self.get_connection()
        conn.autocommit = True
        cursor = conn.cursor()
        
        try:
            # Create test database
            cursor.execute("IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'LoadTestDB') CREATE DATABASE LoadTestDB")
            cursor.execute("USE LoadTestDB")
            
            # Create test tables
            cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='test_table' AND xtype='U')
            CREATE TABLE test_table (
                id INT IDENTITY(1,1) PRIMARY KEY,
                data NVARCHAR(MAX),
                created_date DATETIME DEFAULT GETDATE()
            )
            """)
            
            cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='deadlock_table1' AND xtype='U')
            CREATE TABLE deadlock_table1 (
                id INT PRIMARY KEY,
                value NVARCHAR(100)
            )
            """)
            
            cursor.execute("""
            IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='deadlock_table2' AND xtype='U')
            CREATE TABLE deadlock_table2 (
                id INT PRIMARY KEY,
                value NVARCHAR(100)
            )
            """)
            
            # Insert initial data
            cursor.execute("INSERT INTO deadlock_table1 (id, value) VALUES (1, 'test1'), (2, 'test2')")
            cursor.execute("INSERT INTO deadlock_table2 (id, value) VALUES (1, 'test1'), (2, 'test2')")
            
            print("✅ Test environment ready")
        except Exception as e:
            print(f"❌ Setup error: {e}")
        finally:
            conn.close()
    
    def connection_load_test(self):
        """Generate connection load - affects mssql_connections"""
        print("🔗 Starting connection load test...")
        end_time = time.time() + self.duration
        
        while self.running and time.time() < end_time:
            connections = []
            try:
                # Create multiple connections
                for _ in range(random.randint(10, 20)):
                    conn = self.get_connection()
                    connections.append(conn)
                
                time.sleep(random.uniform(2, 5))
                
                # Close connections
                for conn in connections:
                    try:
                        conn.close()
                    except:
                        pass
                        
            except Exception as e:
                print(f"Connection load error: {e}")
            
            time.sleep(random.uniform(1, 3))
    
    def transaction_load_test(self):
        """Generate transaction load - affects mssql_transactions_total, mssql_batch_requests_total"""
        print("💳 Starting transaction load test...")
        end_time = time.time() + self.duration
        
        while self.running and time.time() < end_time:
            conn = self.get_connection()
            try:
                cursor = conn.cursor()
                cursor.execute("USE LoadTestDB")
                conn.autocommit = False
                
                # Multiple operations in transaction
                for _ in range(random.randint(5, 15)):
                    data = 'x' * random.randint(1000, 5000)  # Large data for I/O
                    cursor.execute("INSERT INTO test_table (data) VALUES (?)", (data,))
                
                if random.random() > 0.2:  # 80% commit rate
                    conn.commit()
                else:
                    conn.rollback()
                    
            except Exception as e:
                print(f"Transaction error: {e}")
                try:
                    conn.rollback()
                except:
                    pass
            finally:
                try:
                    conn.close()
                except:
                    pass
            
            time.sleep(random.uniform(0.1, 0.5))
    
    def deadlock_generator(self):
        """Generate deadlocks - affects mssql_deadlocks_total"""
        print("🔒 Starting deadlock generator...")
        end_time = time.time() + self.duration
        
        def deadlock_session_1():
            while self.running and time.time() < end_time:
                conn = self.get_connection()
                try:
                    cursor = conn.cursor()
                    cursor.execute("USE LoadTestDB")
                    conn.autocommit = False
                    
                    cursor.execute("UPDATE deadlock_table1 SET value = ? WHERE id = 1", (f"session1_{time.time()}",))
                    time.sleep(0.1)
                    cursor.execute("UPDATE deadlock_table2 SET value = ? WHERE id = 1", (f"session1_{time.time()}",))
                    
                    conn.commit()
                except Exception:
                    try:
                        conn.rollback()
                    except:
                        pass
                finally:
                    try:
                        conn.close()
                    except:
                        pass
                time.sleep(random.uniform(0.1, 0.3))
        
        def deadlock_session_2():
            while self.running and time.time() < end_time:
                conn = self.get_connection()
                try:
                    cursor = conn.cursor()
                    cursor.execute("USE LoadTestDB")
                    conn.autocommit = False
                    
                    cursor.execute("UPDATE deadlock_table2 SET value = ? WHERE id = 1", (f"session2_{time.time()}",))
                    time.sleep(0.1)
                    cursor.execute("UPDATE deadlock_table1 SET value = ? WHERE id = 1", (f"session2_{time.time()}",))
                    
                    conn.commit()
                except Exception:
                    try:
                        conn.rollback()
                    except:
                        pass
                finally:
                    try:
                        conn.close()
                    except:
                        pass
                time.sleep(random.uniform(0.1, 0.3))
        
        # Run deadlock sessions in parallel
        threading.Thread(target=deadlock_session_1, daemon=True).start()
        threading.Thread(target=deadlock_session_2, daemon=True).start()
    
    def io_intensive_load(self):
        """Generate I/O load - affects mssql_page_reads_total, mssql_page_writes_total, mssql_io_stall_total"""
        print("💾 Starting I/O intensive load...")
        end_time = time.time() + self.duration
        
        while self.running and time.time() < end_time:
            conn = self.get_connection()
            try:
                cursor = conn.cursor()
                cursor.execute("USE LoadTestDB")
                
                # Large data operations
                operations = [
                    # Bulk insert
                    lambda: [cursor.execute("INSERT INTO test_table (data) VALUES (?)", ('x' * 10000,)) for _ in range(100)],
                    # Full table scan
                    lambda: cursor.execute("SELECT COUNT(*) FROM test_table WHERE data LIKE '%x%'"),
                    # Large update
                    lambda: cursor.execute("UPDATE test_table SET data = ? WHERE id % 10 = 0", ('y' * 10000,)),
                    # Memory intensive query
                    lambda: cursor.execute("SELECT * FROM test_table ORDER BY data DESC"),
                ]
                
                random.choice(operations)()
                
            except Exception as e:
                print(f"I/O load error: {e}")
            finally:
                try:
                    conn.close()
                except:
                    pass
            
            time.sleep(random.uniform(0.2, 1))
    
    def error_generator(self):
        """Generate user errors - affects mssql_user_errors_total"""
        print("❌ Starting error generator...")
        end_time = time.time() + self.duration
        
        while self.running and time.time() < end_time:
            conn = self.get_connection()
            try:
                cursor = conn.cursor()
                
                # Generate various errors
                error_queries = [
                    "SELECT * FROM nonexistent_table",
                    "INSERT INTO nonexistent_table VALUES (1)",
                    "UPDATE nonexistent_table SET col = 1",
                    "SELECT 1/0",  # Division by zero
                    "CONVERT(INT, 'invalid')",  # Conversion error
                ]
                
                try:
                    cursor.execute(random.choice(error_queries))
                except:
                    pass  # Expected errors
                    
            except Exception:
                pass
            finally:
                try:
                    conn.close()
                except:
                    pass
            
            time.sleep(random.uniform(0.5, 2))
    
    def memory_pressure_test(self):
        """Generate memory pressure - affects mssql_memory_utilization_percentage, mssql_page_life_expectancy"""
        print("🧠 Starting memory pressure test...")
        end_time = time.time() + self.duration
        
        while self.running and time.time() < end_time:
            conn = self.get_connection()
            try:
                cursor = conn.cursor()
                cursor.execute("USE LoadTestDB")
                
                # Memory intensive operations
                cursor.execute("""
                WITH LargeDataSet AS (
                    SELECT 
                        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) as rn,
                        REPLICATE('X', 1000) as large_data
                    FROM sys.objects a
                    CROSS JOIN sys.objects b
                )
                SELECT COUNT(*) FROM LargeDataSet
                """)
                
            except Exception as e:
                print(f"Memory pressure error: {e}")
            finally:
                try:
                    conn.close()
                except:
                    pass
            
            time.sleep(random.uniform(1, 3))
    
    def run_comprehensive_test(self):
        """Run all load tests concurrently"""
        print(f"🚀 Starting comprehensive SQL Server load test for {self.duration} seconds...")
        print(f"📊 Target: {self.server}")
        print("=" * 80)
        
        # Setup test environment
        self.setup_test_environment()
        
        # Start all load tests concurrently
        with ThreadPoolExecutor(max_workers=6) as executor:
            futures = [
                executor.submit(self.connection_load_test),
                executor.submit(self.transaction_load_test),
                executor.submit(self.deadlock_generator),
                executor.submit(self.io_intensive_load),
                executor.submit(self.error_generator),
                executor.submit(self.memory_pressure_test),
            ]
            
            # Wait for duration
            time.sleep(self.duration)
            self.running = False
            
            # Wait for all threads to complete
            for future in futures:
                try:
                    future.result(timeout=10)
                except Exception as e:
                    print(f"Thread error: {e}")
        
        print("✅ Comprehensive load test completed!")
        print("📈 Check Grafana dashboard for metric changes in all 22 metrics")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--server', required=True)
    parser.add_argument('--username', required=True) 
    parser.add_argument('--password', required=True)
    parser.add_argument('--duration', type=int, default=300)
    args = parser.parse_args()
    
    try:
        load_test = ComprehensiveSQLServerLoadTest(
            args.server, args.username, args.password, args.duration
        )
        load_test.run_comprehensive_test()
        
    except Exception as e:
        print(f"❌ Load test failed: {e}")

if __name__ == "__main__":
    main()
