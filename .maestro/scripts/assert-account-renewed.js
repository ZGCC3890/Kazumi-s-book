var state = JSON.parse(http.get('http://127.0.0.1:8765/account/state').body);
if (state.logins !== 2) throw new Error('Saved account did not renew exactly once after restart');
