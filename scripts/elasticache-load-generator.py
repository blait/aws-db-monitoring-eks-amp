#!/usr/bin/env python3
"""
ElastiCache Valkey Load Generator
Generates realistic cache traffic to produce meaningful metrics for monitoring dashboards.
"""

import redis
import time
import random
import json
import threading
import signal
import sys
from datetime import datetime, timedelta
import argparse

class ElastiCacheLoadGenerator:
    def __init__(self, host, port=6379, max_connections=10):
        self.host = host
        self.port = port
        self.max_connections = max_connections
        self.running = True
        self.stats = {
            'operations': 0,
            'cache_hits': 0,
            'cache_misses': 0,
            'sets': 0,
            'gets': 0,
            'deletes': 0
        }
        
        # Create connection pool
        self.pool = redis.ConnectionPool(
            host=host,
            port=port,
            max_connections=max_connections,
            decode_responses=True
        )
        
        # Test connection
        try:
            r = redis.Redis(connection_pool=self.pool)
            r.ping()
            print(f"✅ Connected to ElastiCache at {host}:{port}")
        except Exception as e:
            print(f"❌ Failed to connect to ElastiCache: {e}")
            sys.exit(1)

    def generate_user_session_data(self):
        """Generate realistic user session data"""
        user_id = random.randint(1, 1000)
        session_data = {
            'user_id': user_id,
            'login_time': datetime.now().isoformat(),
            'preferences': {
                'theme': random.choice(['dark', 'light']),
                'language': random.choice(['en', 'ko', 'ja', 'zh']),
                'notifications': random.choice([True, False])
            },
            'cart_items': random.randint(0, 10),
            'last_activity': datetime.now().isoformat()
        }
        return f"user:session:{user_id}", json.dumps(session_data)

    def generate_product_cache_data(self):
        """Generate product catalog cache data"""
        product_id = random.randint(1, 500)
        product_data = {
            'id': product_id,
            'name': f'Product {product_id}',
            'price': round(random.uniform(10.0, 999.99), 2),
            'category': random.choice(['electronics', 'clothing', 'books', 'home']),
            'stock': random.randint(0, 100),
            'rating': round(random.uniform(1.0, 5.0), 1)
        }
        return f"product:{product_id}", json.dumps(product_data)

    def cache_hit_scenario(self, r):
        """Simulate cache hit scenario - read existing data"""
        try:
            # Try to read popular items (higher chance of cache hit)
            popular_keys = [
                f"user:session:{random.randint(1, 100)}",  # Popular users
                f"product:{random.randint(1, 50)}",        # Popular products
                "trending:products",
                "featured:items"
            ]
            
            key = random.choice(popular_keys)
            value = r.get(key)
            
            if value:
                self.stats['cache_hits'] += 1
                self.stats['gets'] += 1
            else:
                self.stats['cache_misses'] += 1
                self.stats['gets'] += 1
                
                # On cache miss, populate the cache
                if key.startswith('user:session:'):
                    _, data = self.generate_user_session_data()
                    r.setex(key, 3600, data)  # 1 hour TTL
                elif key.startswith('product:'):
                    _, data = self.generate_product_cache_data()
                    r.setex(key, 7200, data)  # 2 hour TTL
                elif key == "trending:products":
                    trending = [f"product:{i}" for i in range(1, 11)]
                    r.setex(key, 1800, json.dumps(trending))  # 30 min TTL
                elif key == "featured:items":
                    featured = [f"product:{i}" for i in range(1, 6)]
                    r.setex(key, 3600, json.dumps(featured))  # 1 hour TTL
                
                self.stats['sets'] += 1
                
        except Exception as e:
            print(f"Cache hit scenario error: {e}")

    def cache_write_scenario(self, r):
        """Simulate cache write scenario - store new data"""
        try:
            scenario = random.choice(['user_session', 'product_data', 'analytics'])
            
            if scenario == 'user_session':
                key, data = self.generate_user_session_data()
                r.setex(key, random.randint(1800, 7200), data)  # 30min-2hr TTL
            elif scenario == 'product_data':
                key, data = self.generate_product_cache_data()
                r.setex(key, random.randint(3600, 14400), data)  # 1hr-4hr TTL
            elif scenario == 'analytics':
                timestamp = int(time.time())
                analytics_data = {
                    'page_views': random.randint(100, 1000),
                    'unique_visitors': random.randint(50, 500),
                    'bounce_rate': round(random.uniform(0.2, 0.8), 2)
                }
                key = f"analytics:hourly:{timestamp // 3600}"
                r.setex(key, 86400, json.dumps(analytics_data))  # 24hr TTL
            
            self.stats['sets'] += 1
            
        except Exception as e:
            print(f"Cache write scenario error: {e}")

    def cache_cleanup_scenario(self, r):
        """Simulate cache cleanup - delete expired or unused data"""
        try:
            # Delete some random keys to simulate cleanup
            cleanup_patterns = [
                f"user:session:{random.randint(800, 1000)}",  # Less popular users
                f"product:{random.randint(400, 500)}",        # Less popular products
                f"temp:data:{random.randint(1, 100)}"
            ]
            
            key = random.choice(cleanup_patterns)
            deleted = r.delete(key)
            if deleted:
                self.stats['deletes'] += 1
                
        except Exception as e:
            print(f"Cache cleanup scenario error: {e}")

    def worker_thread(self, thread_id):
        """Worker thread that generates load"""
        r = redis.Redis(connection_pool=self.pool)
        
        while self.running:
            try:
                # Weighted scenarios to simulate realistic usage
                scenario = random.choices(
                    ['read', 'write', 'cleanup'],
                    weights=[70, 25, 5],  # 70% reads, 25% writes, 5% cleanup
                    k=1
                )[0]
                
                if scenario == 'read':
                    self.cache_hit_scenario(r)
                elif scenario == 'write':
                    self.cache_write_scenario(r)
                elif scenario == 'cleanup':
                    self.cache_cleanup_scenario(r)
                
                self.stats['operations'] += 1
                
                # Random delay between operations (0.1-2 seconds)
                time.sleep(random.uniform(0.1, 2.0))
                
            except Exception as e:
                print(f"Worker {thread_id} error: {e}")
                time.sleep(1)

    def print_stats(self):
        """Print current statistics"""
        while self.running:
            time.sleep(10)  # Print stats every 10 seconds
            
            total_ops = self.stats['operations']
            if total_ops > 0:
                hit_rate = (self.stats['cache_hits'] / (self.stats['cache_hits'] + self.stats['cache_misses'])) * 100 if (self.stats['cache_hits'] + self.stats['cache_misses']) > 0 else 0
                
                print(f"\n📊 ElastiCache Load Generator Stats:")
                print(f"   Total Operations: {total_ops}")
                print(f"   Cache Hits: {self.stats['cache_hits']}")
                print(f"   Cache Misses: {self.stats['cache_misses']}")
                print(f"   Hit Rate: {hit_rate:.1f}%")
                print(f"   Sets: {self.stats['sets']}")
                print(f"   Gets: {self.stats['gets']}")
                print(f"   Deletes: {self.stats['deletes']}")
                print(f"   Ops/sec: {total_ops / 10:.1f}")
                
                # Reset counter for next interval
                self.stats['operations'] = 0

    def signal_handler(self, signum, frame):
        """Handle shutdown signal"""
        print(f"\n🛑 Received signal {signum}, shutting down gracefully...")
        self.running = False

    def run(self, num_threads=5):
        """Run the load generator"""
        print(f"🚀 Starting ElastiCache load generator with {num_threads} threads")
        print(f"   Target: {self.host}:{self.port}")
        print(f"   Press Ctrl+C to stop")
        
        # Set up signal handlers
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        # Start worker threads
        threads = []
        for i in range(num_threads):
            thread = threading.Thread(target=self.worker_thread, args=(i,))
            thread.daemon = True
            thread.start()
            threads.append(thread)
        
        # Start stats thread
        stats_thread = threading.Thread(target=self.print_stats)
        stats_thread.daemon = True
        stats_thread.start()
        
        # Wait for threads to complete
        try:
            while self.running:
                time.sleep(1)
        except KeyboardInterrupt:
            self.running = False
        
        print("✅ Load generator stopped")

def main():
    parser = argparse.ArgumentParser(description='ElastiCache Valkey Load Generator')
    parser.add_argument('--host', required=True, help='ElastiCache endpoint')
    parser.add_argument('--port', type=int, default=6379, help='ElastiCache port (default: 6379)')
    parser.add_argument('--threads', type=int, default=5, help='Number of worker threads (default: 5)')
    parser.add_argument('--connections', type=int, default=10, help='Max connections in pool (default: 10)')
    
    args = parser.parse_args()
    
    generator = ElastiCacheLoadGenerator(
        host=args.host,
        port=args.port,
        max_connections=args.connections
    )
    
    generator.run(num_threads=args.threads)

if __name__ == "__main__":
    main()