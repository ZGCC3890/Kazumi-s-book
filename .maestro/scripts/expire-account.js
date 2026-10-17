var state = JSON.parse(http.get('http://127.0.0.1:8765/account/state').body);
if (state.logins !== 1) throw new Error('Expected one verified initial login');
var expired = http.get('http://127.0.0.1:8765/account/expire');
if (expired.status !== 200) throw new Error('Could not expire the fixture session');
