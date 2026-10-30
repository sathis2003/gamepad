import socket
import threading
import json
import time
import sys
import platform
import select
import struct
from typing import Dict, Optional, Set
from collections import deque
import queue
import uuid
import logging
import hmac
import secrets

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Global flags
VGAMEPAD_AVAILABLE = False

# Minimal imports for maximum performance
if platform.system() == "Windows":
    try:
        import vgamepad as vg
        VGAMEPAD_AVAILABLE = True
        logger.info("✅ vgamepad ready")
    except ImportError:
        logger.warning("⚠️ vgamepad not installed")


class CricketOptimizedController:
    """Cricket 24 optimized Xbox controller with enhanced error handling"""
    
    def __init__(self, controller_id: int):
        self.controller_id = controller_id
        self.vgamepad = None
        self.active = False
        
        # Enhanced state tracking with thread safety
        self.button_state = {}
        self.button_press_time = {}
        self.button_release_time = {}
        self.last_update = 0
        self.update_lock = threading.RLock()
        
        # Fixed trigger state tracking
        self.trigger_state = {'LT': 0.0, 'RT': 0.0}
        self.trigger_press_time = {}
        
        # Cricket 24 specific timing (more conservative for stability)
        self.min_press_duration = 0.030    # 30ms minimum press
        self.min_release_gap = 0.060       # 60ms gap between presses
        self.max_update_rate = 100         # 100Hz max for better stability
        self.frame_time = 1.0 / self.max_update_rate
        
        # Enhanced cooldown system
        self.button_cooldown = {}
        self.press_sequence = {}
        
        self._init_controller()
    
    def _init_controller(self):
        """Initialize controller with better error handling"""
        if not VGAMEPAD_AVAILABLE:
            logger.warning(f"Controller {self.controller_id}: vgamepad not available")
            return
            
        try:    
            self.vgamepad = vg.VX360Gamepad()
            self.active = True
            
            # Reset to known state
            self.vgamepad.reset()
            self.vgamepad.update()
            
            # Initialize all tracked states
            for button in ['A', 'B', 'X', 'Y', 'LB', 'RB', 'LT', 'RT', 
                          'START', 'BACK', 'LS', 'RS', 'UP', 'DOWN', 'LEFT', 'RIGHT']:
                self.button_state[button] = False
                self.button_press_time[button] = 0
                self.button_release_time[button] = 0
                self.button_cooldown[button] = 0
            
            # Initialize trigger states
            self.trigger_state = {'LT': 0.0, 'RT': 0.0}
            self.trigger_press_time = {'LT': 0, 'RT': 0}
            
            logger.info(f"🎮 Controller {self.controller_id} initialized")
            
        except Exception as e:
            logger.error(f"❌ Controller {self.controller_id} initialization failed: {e}")
            self.active = False
    
    def _is_button_on_cooldown(self, button: str) -> bool:
        """Check if button is on cooldown with better timing"""
        current_time = time.time()
        cooldown_end = self.button_cooldown.get(button, 0)
        return current_time < cooldown_end
    
    def _set_button_cooldown(self, button: str, duration: float = 0.060):
        """Set cooldown period for button"""
        self.button_cooldown[button] = time.time() + duration
    
    def press_trigger(self, trigger: str):
        """Press trigger with improved error handling"""
        if not self.active or trigger not in ['RT', 'LT']:
            return False
            
        current_time = time.time()
        
        if self._is_button_on_cooldown(trigger):
            logger.debug(f"🔥 {trigger} on cooldown - ignoring")
            return False
        
        try:
            with self.update_lock:
                self.trigger_state[trigger] = 1.0
                self.trigger_press_time[trigger] = current_time
                
                if trigger == 'LT':
                    self.vgamepad.left_trigger_float(1.0)
                elif trigger == 'RT':
                    self.vgamepad.right_trigger_float(1.0)
                
                self.vgamepad.update()
                self.last_update = current_time
                
                self._set_button_cooldown(trigger, self.min_release_gap)
                
            logger.debug(f"⚡ P{self.controller_id}: {trigger} TRIGGER PRESSED")
            return True
            
        except Exception as e:
            logger.error(f"❌ Trigger press error {trigger}: {e}")
            return False
    
    def release_trigger(self, trigger: str):
        """Release trigger with improved error handling"""
        if not self.active or trigger not in ['RT', 'LT']:
            return False
        
        try:
            with self.update_lock:
                self.trigger_state[trigger] = 0.0
                
                if trigger == 'LT':
                    self.vgamepad.left_trigger_float(0.0)
                elif trigger == 'RT':
                    self.vgamepad.right_trigger_float(0.0)
                
                self.vgamepad.update()
                self._set_button_cooldown(trigger, self.min_release_gap)
                
            logger.debug(f"🔥 P{self.controller_id}: {trigger} TRIGGER RELEASED")
            return True
            
        except Exception as e:
            logger.error(f"❌ Trigger release error {trigger}: {e}")
            return False
    
    def press_button(self, button: str, force: bool = False):
        """Press button with enhanced anti-repeat protection"""
        if not self.active:
            return False
            
        current_time = time.time()
        
        # Rate limiting for stability
        if current_time - self.last_update < self.frame_time:
            return False
        
        if not force and self._is_button_on_cooldown(button):
            logger.debug(f"🔥 {button} on cooldown - ignoring")
            return False
            
        button_map = self._get_button_mapping(button)
        if not button_map:
            return False
            
        # Prevent double-press
        if self.button_state.get(button, False):
            logger.debug(f"⚠️ {button} already pressed - phantom prevention")
            return False
            
        try:
            with self.update_lock:
                self.button_state[button] = True
                self.button_press_time[button] = current_time
                
                self.vgamepad.press_button(button_map)
                self.vgamepad.update()
                self.last_update = current_time
                
                self._set_button_cooldown(button, self.min_release_gap)
                
            logger.debug(f"⚡ P{self.controller_id}: {button} PRESSED")
            return True
            
        except Exception as e:
            logger.error(f"❌ Press error {button}: {e}")
            return False
    
    def release_button(self, button: str, force: bool = False):
        """Release button with timing validation"""
        if not self.active:
            return False
            
        current_time = time.time()
        button_map = self._get_button_mapping(button)
        if not button_map:
            return False
            
        if not self.button_state.get(button, False):
            logger.debug(f"⚠️ {button} not pressed - ignoring release")
            return False
        
        # Check minimum press duration
        press_time = self.button_press_time.get(button, 0)
        if not force and (current_time - press_time) < self.min_press_duration:
            logger.debug(f"⏱️ {button} press too short - extending")
            threading.Timer(
                self.min_press_duration - (current_time - press_time), 
                lambda: self.release_button(button, force=True)
            ).start()
            return True
            
        try:
            with self.update_lock:
                self.button_state[button] = False
                self.button_release_time[button] = current_time
                
                self.vgamepad.release_button(button_map)
                self.vgamepad.update()
                
                self._set_button_cooldown(button, self.min_release_gap)
                
            logger.debug(f"🔥 P{self.controller_id}: {button} RELEASED")
            return True
            
        except Exception as e:
            logger.error(f"❌ Release error {button}: {e}")
            return False
    
    def cricket_tap(self, button: str):
        """Cricket 24 optimized single tap"""
        if not self.active:
            return False
            
        if self._is_button_on_cooldown(button):
            logger.debug(f"🔥 {button} tap on cooldown")
            return False
            
        button_map = self._get_button_mapping(button)
        if not button_map:
            return False
            
        try:
            with self.update_lock:
                current_time = time.time()
                
                self.vgamepad.press_button(button_map)
                self.vgamepad.update()
                
                time.sleep(0.030)  # 30ms hold for better recognition
                
                self.vgamepad.release_button(button_map)
                self.vgamepad.update()
                
                self.button_press_time[button] = current_time
                self.button_release_time[button] = current_time + 0.030
                
                self._set_button_cooldown(button, 0.100)  # 100ms cooldown for taps
                
            logger.debug(f"⚡ P{self.controller_id}: {button} CRICKET TAP")
            return True
            
        except Exception as e:
            logger.error(f"❌ tap error {button}: {e}")
            return False
    
    def update_trigger(self, trigger: str, value: float):
        """Update trigger value"""
        if not self.active:
            return False
            
        value = max(0.0, min(1.0, value))
        
        try:
            with self.update_lock:
                if trigger == 'LT':
                    self.vgamepad.left_trigger_float(value)
                    self.trigger_state['LT'] = value
                elif trigger == 'RT':
                    self.vgamepad.right_trigger_float(value)
                    self.trigger_state['RT'] = value
                else:
                    return False
                    
                self.vgamepad.update()
                return True
                
        except Exception as e:
            logger.error(f"❌ Trigger error {trigger}: {e}")
            return False
    
    def update_stick(self, stick: str, x: float, y: float):
        """Update joystick with proper deadzone"""
        if not self.active:
            return False
            
        # Cricket 24 optimized deadzone
        deadzone = 0.12
        if abs(x) < deadzone:
            x = 0.0
        if abs(y) < deadzone:
            y = 0.0
            
        x = max(-1.0, min(1.0, x))
        y = max(-1.0, min(1.0, y))
        
        try:
            with self.update_lock:
                if stick == 'left':
                    self.vgamepad.left_joystick_float(x_value_float=x, y_value_float=-y)
                elif stick == 'right':
                    self.vgamepad.right_joystick_float(x_value_float=x, y_value_float=-y)
                else:
                    return False
                    
                self.vgamepad.update()
                return True
                
        except Exception as e:
            logger.error(f"❌ Stick error {stick}: {e}")
            return False
    
    def _get_button_mapping(self, button: str):
        """Get vgamepad button mapping"""
        mappings = {
            'A': vg.XUSB_BUTTON.XUSB_GAMEPAD_A,
            'B': vg.XUSB_BUTTON.XUSB_GAMEPAD_B,
            'X': vg.XUSB_BUTTON.XUSB_GAMEPAD_X,
            'Y': vg.XUSB_BUTTON.XUSB_GAMEPAD_Y,
            'LB': vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_SHOULDER,
            'RB': vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_SHOULDER,
            'BACK': vg.XUSB_BUTTON.XUSB_GAMEPAD_BACK,
            'VIEW': vg.XUSB_BUTTON.XUSB_GAMEPAD_BACK,
            'START': vg.XUSB_BUTTON.XUSB_GAMEPAD_START,
            'MENU': vg.XUSB_BUTTON.XUSB_GAMEPAD_START,
            'LS': vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_THUMB,
            'RS': vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_THUMB,
            'UP': vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP,
            'DOWN': vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_DOWN,
            'LEFT': vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_LEFT,
            'RIGHT': vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_RIGHT,
            'APPEAL': vg.XUSB_BUTTON.XUSB_GAMEPAD_DPAD_UP,
            'REVIEW': vg.XUSB_BUTTON.XUSB_GAMEPAD_Y,
            'SHOT': vg.XUSB_BUTTON.XUSB_GAMEPAD_A,
            'DEFEND': vg.XUSB_BUTTON.XUSB_GAMEPAD_B,
            'PAUSE': vg.XUSB_BUTTON.XUSB_GAMEPAD_START,
        }
        return mappings.get(button)
    
    def emergency_reset(self):
        """Emergency reset for controller"""
        if not self.active:
            return
            
        try:
            with self.update_lock:
                self.vgamepad.reset()
                self.vgamepad.update()
                
                # Clear all state tracking
                self.button_state.clear()
                self.button_press_time.clear()
                self.button_release_time.clear()
                self.button_cooldown.clear()
                
                # Reset trigger states
                self.trigger_state = {'LT': 0.0, 'RT': 0.0}
                self.trigger_press_time = {'LT': 0, 'RT': 0}
                
                # Reinitialize essential state
                for button in ['A', 'B', 'X', 'Y', 'LB', 'RB', 'START', 'BACK']:
                    self.button_state[button] = False
                    self.button_cooldown[button] = 0
                
            logger.info(f"🔥 Controller {self.controller_id} reset")
            
        except Exception as e:
            logger.error(f"❌ Reset error: {e}")


class CricketInputProcessor:
    """Enhanced input processor with better message handling"""
    
    def __init__(self, controller_id: int, controller: CricketOptimizedController):
        self.controller_id = controller_id
        self.controller = controller
        
        # Message deduplication
        self.message_dedup = {}
        self.max_dedup = 1000
        self.dedup_timeout = 2.0
        
        # Performance tracking
        self.messages_processed = 0
        self.last_stats_time = time.time()
        
    def process_input(self, message_data: str, client_address: str = "unknown"):
        """Process Cricket 24 input with better error handling"""
        
        current_time = time.time()
        
        # Message deduplication
        message_hash = hash(message_data)
        if message_hash in self.message_dedup:
            last_time = self.message_dedup[message_hash]
            if current_time - last_time < 0.050:  # 50ms dedup window
                return False
        
        self.message_dedup[message_hash] = current_time
        
        # Clean old dedup entries
        if len(self.message_dedup) > self.max_dedup:
            self._clean_dedup_cache(current_time)
        
        try:
            message = json.loads(message_data)
            msg_type = message.get('type', '').lower()
            
            self.messages_processed += 1
            
            # Route message types
            success = False
            if 'button' in message:
                success = self._handle_cricket_button(message)
            elif 'trigger' in message:
                success = self._handle_cricket_trigger(message)
            elif 'joystick' in message:
                success = self._handle_cricket_joystick(message)
            elif msg_type == 'reset_all':
                self.controller.emergency_reset()
                success = True
            elif msg_type in ['heartbeat', 'ping', 'cricket_handshake', 'cricket_test']:
                success = True  # Acknowledge but don't process
            
            # Performance reporting
            if current_time - self.last_stats_time > 30.0:  # Every 30 seconds
                rate = self.messages_processed / (current_time - self.last_stats_time)
                logger.info(f"📊 P{self.controller_id}: {rate:.1f} msg/s")
                self.messages_processed = 0
                self.last_stats_time = current_time
            
            return success
                
        except json.JSONDecodeError as e:
            logger.warning(f"🚫 P{self.controller_id}: JSON error - {e}")
            return False
        except Exception as e:
            logger.error(f"❌ P{self.controller_id}: Processing error - {e}")
            return False
    
    def _clean_dedup_cache(self, current_time: float):
        """Clean old deduplication entries"""
        cutoff_time = current_time - self.dedup_timeout
        self.message_dedup = {
            k: v for k, v in self.message_dedup.items() 
            if v > cutoff_time
        }
    
    def _handle_cricket_trigger(self, message) -> bool:
        """Handle Cricket 24 trigger input"""
        trigger = str(message.get('trigger', '')).upper().strip()
        trigger_type = message.get('type', 'trigger_press').lower()
        
        if trigger not in ['RT', 'LT']:
            return False
        
        if trigger_type == 'trigger_press':
            return self.controller.press_trigger(trigger)
        elif trigger_type == 'trigger_release':
            return self.controller.release_trigger(trigger)
        else:
            # Handle as analog value
            try:
                value = float(message.get('value', 0.0))
                return self.controller.update_trigger(trigger, value)
            except (ValueError, TypeError):
                return False
    
    def _handle_cricket_button(self, message) -> bool:
        """Handle Cricket 24 button input"""
        button = str(message.get('button', '')).upper().strip()
        press_type = message.get('type', 'press').lower()
        
        if not button:
            return False
        
        if press_type == 'press':
            return self.controller.press_button(button)
        elif press_type == 'release':
            return self.controller.release_button(button)
        elif press_type in ['instant', 'tap']:
            return self.controller.cricket_tap(button)
        else:
            logger.warning(f"🚫 Unknown press type: {press_type}")
            return False
    
    def _handle_cricket_joystick(self, message) -> bool:
        """Handle Cricket 24 joystick input"""
        stick_id = message.get('joystick', 'left')
        
        try:
            x = float(message.get('x', 0.0))
            y = float(message.get('y', 0.0))
        except (ValueError, TypeError):
            return False
        
        return self.controller.update_stick(stick_id, x, y)


class CricketGamepadServer:
    """Cricket 24 server with improved stability and error handling"""
    
    def __init__(self, host='0.0.0.0', port=8080, max_players=4):
        self.host = host
        self.port = port
        self.max_players = max_players
        self.running = False
        
        # Client management
        self.controllers = {}
        self.processors = {}
        self.clients = {}
        self.client_threads = {}
        self.client_lock = threading.RLock()
        
        # Performance monitoring
        self.start_time = time.time()
        self.total_connections = 0
        self.active_connections = 0
        
        self._init_cricket_controllers()
        
        logger.info(f"🎮 Gamepad Server")
        logger.info(f"📡 {host}:{port} | Players: {max_players}")
        logger.info(f"⚡ Low-latency input")
    
    def _init_cricket_controllers(self):
        """Initialize controller pool"""
        for i in range(1, self.max_players + 1):
            controller = CricketOptimizedController(i)
            processor = CricketInputProcessor(i, controller)
            
            self.controllers[i] = controller
            self.processors[i] = processor
        
        active = sum(1 for c in self.controllers.values() if c.active)
        logger.info(f"🎮 Controllers: {active}/{len(self.controllers)} active")
        
        if active == 0:
            logger.warning("⚠️ No active controllers - check vgamepad installation")
    
    def _assign_controller(self, client_socket, client_address):
        """Assign controller to client"""
        with self.client_lock:
            for cid in range(1, self.max_players + 1):
                if cid not in self.clients:
                    client_id = f"cricket_player_{cid}_{int(time.time())}"
                    self.clients[cid] = {
                        'socket': client_socket,
                        'id': client_id,
                        'address': client_address,
                        'connected_at': time.time(),
                        'last_activity': time.time(),
                        'messages_received': 0,
                        'connection_stable': False,
                        'udp_token': secrets.token_hex(16)  # UDP datagrams must start with this
                    }
                    self.total_connections += 1
                    self.active_connections += 1
                    logger.info(f"🎮 Player {cid} connected from {client_address[0]}")
                    return cid
        return None
    
    def _handle_client(self, client_socket, controller_id, client_address):
        """Handle client connection with better error recovery"""
        processor = self.processors[controller_id]
        buffer = ""
        client_info = f"P{controller_id}@{client_address[0]}"
        
        try:
            # Socket optimization
            client_socket.settimeout(10.0)
            client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            
            try:
                client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
                client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
            except Exception as e:
                logger.warning(f"⚠️ {client_info}: Buffer optimization failed - {e}")
            
            # Send welcome message
            welcome_msg = json.dumps({
                'type': 'cricket_welcome', 
                'player_id': controller_id,
                'status': 'connected',
                'server_version': 'cricket_v3_stable',
                'max_update_rate': 100,
                'udp_port': self.port,
                'udp_token': self.clients[controller_id]['udp_token'],
                'features': ['anti_repeat', 'cricket_optimized', 'enhanced_timing', 'trigger_support', 'stability', 'udp_input']
            }) + '\n'
            
            try:
                client_socket.send(welcome_msg.encode('utf-8'))
                logger.info(f"🏏 {client_info}: Welcome sent")
            except Exception as e:
                logger.error(f"❌ {client_info}: Welcome send failed - {e}")
            
            # Mark connection as stable
            with self.client_lock:
                if controller_id in self.clients:
                    self.clients[controller_id]['connection_stable'] = True
            
            message_count = 0
            last_perf_report = time.time()
            
            while self.running:
                try:
                    # Non-blocking receive
                    ready = select.select([client_socket], [], [], 2.0)
                    if not ready[0]:
                        if not self._is_client_active(controller_id):
                            logger.info(f"🏏 {client_info}: Client inactive, disconnecting")
                            break
                        continue
                    
                    data = client_socket.recv(8192)
                    if not data:
                        logger.info(f"🏏 {client_info}: Client disconnected normally")
                        break
                    
                    # Decode with error handling
                    try:
                        decoded_data = data.decode('utf-8', errors='replace')
                    except UnicodeDecodeError as e:
                        logger.warning(f"🚫 {client_info}: Decode error - {e}")
                        continue
                    
                    buffer += decoded_data
                    
                    # Process complete messages
                    while '\n' in buffer:
                        line, buffer = buffer.split('\n', 1)
                        line = line.strip()
                        
                        if line:
                            self._update_client_activity(controller_id)
                            
                            if processor.process_input(line, str(client_address)):
                                message_count += 1
                
                    # Performance reporting
                    current_time = time.time()
                    if current_time - last_perf_report > 60.0:  # Every minute
                        rate = message_count / (current_time - last_perf_report)
                        logger.info(f"🏏 {client_info}: {rate:.1f} msg/s, {message_count} total")
                        message_count = 0
                        last_perf_report = current_time
                
                except socket.timeout:
                    if not self._is_client_active(controller_id):
                        logger.info(f"🏏 {client_info}: Timeout, client inactive")
                        break
                    continue
                    
                except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError) as e:
                    logger.info(f"🏏 {client_info}: Connection lost - {e}")
                    break
                    
                except Exception as e:
                    logger.error(f"❌ {client_info}: Handler error - {e}")
                    continue  # Try to continue on non-critical errors
        
        except Exception as e:
            logger.error(f"❌ {client_info}: Critical handler error - {e}")
        finally:
            self._disconnect_client(controller_id)
    
    def _is_client_active(self, controller_id: int) -> bool:
        """Check if client is still active"""
        with self.client_lock:
            if controller_id not in self.clients:
                return False
            
            client = self.clients[controller_id]
            current_time = time.time()
            
            # 120 seconds timeout for better stability
            if current_time - client['last_activity'] > 120.0:
                return False
            
            return True
    
    def _update_client_activity(self, controller_id: int):
        """Update client activity timestamp"""
        with self.client_lock:
            if controller_id in self.clients:
                self.clients[controller_id]['last_activity'] = time.time()
                self.clients[controller_id]['messages_received'] += 1
    
    def _disconnect_client(self, controller_id: int):
        """Clean disconnect with proper cleanup"""
        with self.client_lock:
            if controller_id in self.clients:
                client = self.clients[controller_id]
                duration = time.time() - client['connected_at']
                msg_count = client.get('messages_received', 0)
                
                try:
                    goodbye_msg = json.dumps({
                        'type': 'cricket_disconnect', 
                        'status': 'confirmed',
                        'session_duration': round(duration, 1),
                        'messages_processed': msg_count
                    }) + '\n'
                    client['socket'].send(goodbye_msg.encode('utf-8'))
                except:
                    pass
                
                try:
                    client['socket'].close()
                except:
                    pass
                
                del self.clients[controller_id]
                self.active_connections -= 1
                
                # Reset controller
                self.controllers[controller_id].emergency_reset()
                
                logger.info(f"🎮 Player {controller_id} disconnected")
                logger.info(f"   Duration: {duration:.1f}s, Messages: {msg_count}")
    
    def start_server(self):
        """Start Cricket 24 server with improved error handling"""
        try:
            self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            
            # Socket optimization
            self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.server_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            
            # Platform specific optimizations
            if platform.system() != "Windows":
                try:
                    self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                except:
                    pass
            
            # Better port binding error handling
            try:
                self.server_socket.bind((self.host, self.port))
            except OSError as e:
                if e.errno == 98 or "Address already in use" in str(e):
                    logger.error(f"❌ Port {self.port} is already in use!")
                    logger.info("💡 Solutions:")
                    logger.info("   • Close any existing server instances")
                    logger.info("   • Wait 30 seconds and try again")
                    logger.info("   • Use a different port (e.g., 8081)")
                    if platform.system() == "Windows":
                        logger.info("   • Check Task Manager for python.exe processes")
                    else:
                        logger.info(f"   • Run: sudo lsof -i :{self.port}")
                    return
                else:
                    raise
            
            self.server_socket.listen(self.max_players * 2)
            self.server_socket.settimeout(3.0)
            
            self.running = True

            # UDP on the same port number for input packets (TCP stays for handshake/heartbeat)
            self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.udp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.udp_socket.bind((self.host, self.port))
            self.udp_socket.settimeout(1.0)
            threading.Thread(target=self._udp_loop, daemon=True, name="Cricket-UDP").start()

            # Get network interfaces
            local_ips = self._get_cricket_network_info()
            
            logger.info(f"\n🚀 Server Ready!")
            logger.info(f"📡 Listening on port {self.port}")
            logger.info(f"🎮 Low-latency input")
            logger.info(f"📱 Connect your devices to any of these addresses:")
            for ip in local_ips:
                logger.info(f"   • {ip}:{self.port}")
            logger.info(f"🎮 Supporting {self.max_players} players simultaneously")
            logger.info(f"⚡ Anti-repeat protection enabled")
            logger.info(f"🔥 Press Ctrl+C to stop server")
            logger.info("=" * 60)
            
            # Main server loop
            while self.running:
                try:
                    client_socket, addr = self.server_socket.accept()
                    client_ip = addr[0]
                    logger.info(f"📱 New connection from {client_ip}:{addr[1]}")
                    
                    # Client socket optimization
                    try:
                        client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                        client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                        
                        # Platform specific optimizations
                        if platform.system() == "Linux":
                            client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 30)
                            client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 5)
                            client_socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
                        
                        client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
                        client_socket.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 32768)
                        
                    except Exception as e:
                        logger.warning(f"⚠️ {client_ip}: Socket optimization failed - {e}")
                    
                    # Assign controller
                    controller_id = self._assign_controller(client_socket, addr)
                    
                    if controller_id is None:
                        logger.warning(f"🚫 server full ({self.active_connections}/{self.max_players})")
                        try:
                            reject_msg = json.dumps({
                                'type': 'cricket_server_full', 
                                'message': f'Cricket server full ({self.max_players} players max)',
                                'max_players': self.max_players,
                                'active_players': self.active_connections,
                                'retry_suggestion': 'Try again in a few minutes'
                            }) + '\n'
                            client_socket.send(reject_msg.encode('utf-8'))
                            time.sleep(0.1)
                        except:
                            pass
                        client_socket.close()
                        continue
                    
                    # Start client handler
                    client_thread = threading.Thread(
                        target=self._handle_client,
                        args=(client_socket, controller_id, addr),
                        daemon=True,
                        name=f"Cricket-Player-{controller_id}"
                    )
                    
                    self.client_threads[controller_id] = client_thread
                    client_thread.start()
                
                except socket.timeout:
                    self._perform_maintenance()
                    continue
                    
                except Exception as e:
                    if self.running:
                        logger.error(f"❌ Accept error: {e}")
                        time.sleep(0.1)
        
        except KeyboardInterrupt:
            logger.info("\n🎮 server stopped by user")
        except Exception as e:
            logger.error(f"❌ Critical server error: {e}")
            import traceback
            traceback.print_exc()
        finally:
            self.shutdown()
    
    def _udp_loop(self):
        """Route UDP input packets by the 32-hex-char session token they start with"""
        while self.running:
            try:
                data, addr = self.udp_socket.recvfrom(8192)
            except socket.timeout:
                continue
            except OSError:
                break

            if data == b'POCKETPAD_DISCOVER':
                # LAN broadcast from the app's PC list; firewall limits this to the local subnet
                reply = json.dumps({'pocketpad': 1, 'name': socket.gethostname(), 'port': self.port})
                try:
                    self.udp_socket.sendto(reply.encode('utf-8'), addr)
                except OSError:
                    pass
                continue

            token, payload = data[:32], data[32:]
            with self.client_lock:
                controller_id = next(
                    (cid for cid, c in self.clients.items()
                     if hmac.compare_digest(c['udp_token'].encode(), token)), None
                )
            if controller_id is None:
                continue  # unknown or forged sender

            processor = self.processors[controller_id]
            for line in payload.decode('utf-8', errors='replace').split('\n'):
                line = line.strip()
                if line:
                    self._update_client_activity(controller_id)
                    processor.process_input(line, str(addr))

    def _perform_maintenance(self):
        """Periodic maintenance"""
        current_time = time.time()
        uptime = current_time - self.start_time
        
        # Report server status every 5 minutes
        if int(uptime) % 300 == 0 and int(uptime) > 0:
            logger.info(f"🎮 Server Status: {self.active_connections}/{self.max_players} players, "
                       f"uptime: {uptime/3600:.1f}h, total connections: {self.total_connections}")
    
    def shutdown(self):
        """Clean shutdown"""
        logger.info("\n🔥 Shutting down server...")
        self.running = False
        
        # Stop all client threads
        with self.client_lock:
            for controller_id in list(self.clients.keys()):
                self._disconnect_client(controller_id)
        
        # Wait for threads to finish
        for thread in self.client_threads.values():
            try:
                thread.join(timeout=2.0)
            except:
                pass
        
        # Reset all controllers
        for controller in self.controllers.values():
            controller.emergency_reset()
        
        # Close server socket
        if hasattr(self, 'udp_socket'):
            try:
                self.udp_socket.close()
            except:
                pass
        if hasattr(self, 'server_socket'):
            try:
                self.server_socket.close()
                logger.info("📡 server socket closed")
            except:
                pass
        
        uptime = time.time() - self.start_time
        logger.info(f"🎮 server shutdown complete")
        logger.info(f"   Session duration: {uptime/3600:.1f} hours")
        logger.info(f"   Total connections served: {self.total_connections}")
    
    def _get_cricket_network_info(self):
        """Get network information for setup"""
        local_ips = []
        
        try:
            # Primary IP detection
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.connect(("8.8.8.8", 80))
                primary_ip = s.getsockname()[0]
                local_ips.append(primary_ip)
        except:
            pass
        
        try:
            # Enhanced IP detection
            import subprocess
            
            if platform.system() == "Windows":
                result = subprocess.run(['ipconfig'], capture_output=True, text=True,
                                        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                lines = result.stdout.split('\n')
                for line in lines:
                    if 'IPv4 Address' in line and ':' in line:
                        ip = line.split(':')[1].strip()
                        if ip and ip not in local_ips and not ip.startswith('127.') and not ip.startswith('169.254.'):
                            local_ips.append(ip)
            else:
                try:
                    hostname = socket.gethostname()
                    host_ips = socket.getaddrinfo(hostname, None, socket.AF_INET)
                    for info in host_ips:
                        ip = info[4][0]
                        if ip not in local_ips and not ip.startswith('127.'):
                            local_ips.append(ip)
                except:
                    pass
        except:
            pass
        
        # Fallback
        if not local_ips:
            local_ips.append("127.0.0.1")
        
        # Sort by preference
        def ip_priority(ip):
            if ip.startswith('192.168.'):
                return 0
            elif ip.startswith('10.'):
                return 1
            elif ip.startswith('172.'):
                return 2
            elif ip.startswith('127.'):
                return 9
            else:
                return 5
        
        local_ips.sort(key=ip_priority)
        return list(dict.fromkeys(local_ips))  # dedupe, keep priority order


def main():
    """Cricket 24 main entry point with better error handling"""
    print("🏏 Cricket 24 Ultra-Fast Gamepad Server")
    print("=" * 60)
    print(f"OS: {platform.system()}")
    print(f"Python: {sys.version.split()[0]}")
    print(f"vgamepad: {'✅ Available' if VGAMEPAD_AVAILABLE else '❌ Missing'}")
    
    if not VGAMEPAD_AVAILABLE and platform.system() == "Windows":
        print("\n📦 For Cricket 24 controller support:")
        print("   pip install vgamepad")
        print("   (Xbox controller emulation will be disabled)")
        print("\n⚠️ Without vgamepad, controller inputs won't work!")
        print("💡 Install vgamepad and restart for full functionality")
    
    print("\n🏏 Cricket 24 Enhanced Features:")
    print("   • Anti-repeat button protection")
    print("   • 30ms minimum press duration")
    print("   • 60ms cooldown between presses")
    print("   • Enhanced deadzone handling")
    print("   • RT/LT trigger support")
    print("   • Improved network stability")
    print("   • Better error handling")
    print("   • Performance monitoring")
    print("=" * 60)
    
    # Enhanced port conflict detection
    test_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        test_socket.bind(('localhost', 8080))
        test_socket.close()
    except OSError as e:
        print(f"\n⚠️ Port 8080 conflict detected!")
        print("🔍 Checking for existing processes...")
        
        if platform.system() == "Windows":
            try:
                import subprocess
                result = subprocess.run(['netstat', '-ano', '|', 'findstr', ':8080'], 
                                      capture_output=True, text=True, shell=True)
                if result.stdout:
                    print("📊 Processes using port 8080:")
                    print(result.stdout)
            except:
                pass
        
        print("💡 Solutions:")
        print("   • Close any existing gamepad servers")
        print("   • Wait 30-60 seconds and try again")
        print("   • Restart your computer if needed")
        return 1
    
    # Create and start server
    server = CricketGamepadServer(host='0.0.0.0', port=8080, max_players=4)
    
    try:
        server.start_server()
        return 0
    except KeyboardInterrupt:
        logger.info("\n🎮 server stopped by user")
        return 0
    except Exception as e:
        logger.error(f"❌ Critical server error: {e}")
        logger.error(f"🔍 Error type: {type(e).__name__}")
        
        import traceback
        logger.error("\n📋 Full error details:")
        traceback.print_exc()
        
        logger.info("\n💡 Troubleshooting suggestions:")
        logger.info("   • Ensure you have administrator/sudo privileges")
        logger.info("   • Check firewall settings")
        logger.info("   • Verify vgamepad installation: pip install vgamepad")
        logger.info("   • Try running as administrator")
        return 1
    finally:
        try:
            server.shutdown()
        except:
            pass


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)