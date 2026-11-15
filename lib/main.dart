import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'app_services.dart';

const ink = Color(0xFF192B3A);
const teal = Color(0xFF087E80);

class Book {
  Book({
    required this.key,
    required this.title,
    required this.authors,
    required this.year,
    required this.subjects,
    this.coverId,
  });
  final String key, title, authors, year;
  final List<String> subjects;
  final int? coverId;
  factory Book.fromJson(Map<String, dynamic> j) => Book(
    key: (j['key'] ?? '').toString(),
    title: (j['title'] ?? 'Sin título').toString(),
    authors: ((j['author_name'] as List?) ?? const []).take(3).join(', '),
    year: (j['first_publish_year'] ?? '—').toString(),
    subjects: ((j['subject'] as List?) ?? const [])
        .take(8)
        .map((e) => e.toString())
        .toList(),
    coverId: j['cover_i'] is int ? j['cover_i'] as int : null,
  );
  Map<String, Object?> toMap() => {
    'key': key,
    'title': title,
    'authors': authors,
    'year': year,
    'subjects': jsonEncode(subjects),
    'cover_id': coverId,
  };
  Map<String, dynamic> toServerData() => {
    'title': title,
    'authors': authors,
    'year': year,
    'subjects': subjects,
    'cover_id': coverId,
  };
  factory Book.fromMap(Map<String, Object?> m) => Book(
    key: m['key'] as String,
    title: m['title'] as String,
    authors: m['authors'] as String,
    year: m['year'] as String,
    subjects: (jsonDecode(m['subjects'] as String) as List).cast<String>(),
    coverId: m['cover_id'] as int?,
  );
}

class LocalStore {
  static Database? _db;
  static Future<Database>? _opening;
  static Future<Database> get db {
    if (_db != null) return Future.value(_db!);
    return _opening ??= _open();
  }

  static Future<Database> _open() async =>
      openDatabase(
        p.join(await getDatabasesPath(), 'practica5.db'),
        version: 3,
        onCreate: (d, _) async {
          await d.execute(
            'CREATE TABLE books (key TEXT PRIMARY KEY, title TEXT, authors TEXT, year TEXT, subjects TEXT, cover_id INTEGER, updated_at TEXT)',
          );
          await d.execute(
            'CREATE TABLE favorites (user_id TEXT, book_key TEXT, PRIMARY KEY(user_id, book_key))',
          );
          await d.execute(
            'CREATE TABLE history (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT, query TEXT, searched_at TEXT)',
          );
          await d.execute(
            "CREATE TABLE pending_ops (id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT 'invitado', type TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL)",
          );
        },
        onUpgrade: (d, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await d.execute(
              "CREATE TABLE pending_ops (id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT 'invitado', type TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL)",
            );
          }
          if (oldVersion >= 2 && oldVersion < 3) {
            await d.execute(
              "ALTER TABLE pending_ops ADD COLUMN user_id TEXT NOT NULL DEFAULT 'invitado'",
            );
          }
        },
      ).then((opened) {
        _db = opened;
        return opened;
      });
  static Future<void> cache(List<Book> books) async {
    final d = await db, batch = d.batch();
    final now = DateTime.now().toIso8601String();
    for (final b in books) {
      final m = b.toMap()..['updated_at'] = now;
      batch.insert('books', m, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Book>> cached() async => (await (await db).query(
    'books',
    orderBy: 'updated_at DESC',
  )).map(Book.fromMap).toList();
  static Future<List<Book>> favorites(String u) async {
    final rows = await (await db).rawQuery(
      'SELECT b.* FROM books b JOIN favorites f ON b.key=f.book_key WHERE f.user_id=? ORDER BY b.title',
      [u],
    );
    return rows.map(Book.fromMap).toList();
  }

  static Future<bool> isFavorite(String u, String k) async =>
      (await (await db).query(
        'favorites',
        where: 'user_id=? AND book_key=?',
        whereArgs: [u, k],
      )).isNotEmpty;
  static Future<void> toggle(String u, Book b) async {
    final d = await db;
    await d.transaction((txn) async {
      final existing = await txn.query(
        'favorites',
        where: 'user_id=? AND book_key=?',
        whereArgs: [u, b.key],
      );
      final active = existing.isEmpty;
      final now = DateTime.now().toUtc().toIso8601String();
      final row = b.toMap()..['updated_at'] = now;
      await txn.insert(
        'books',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (active) {
        await txn.insert('favorites', {
          'user_id': u,
          'book_key': b.key,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      } else {
        await txn.delete(
          'favorites',
          where: 'user_id=? AND book_key=?',
          whereArgs: [u, b.key],
        );
      }
      if (u != 'invitado') {
        await txn.insert('pending_ops', {
          'id': _operationId(),
          'user_id': u,
          'type': 'favorite',
          'payload': jsonEncode({
            'key': b.key,
            'active': active,
            'book': _syncData(b),
          }),
          'created_at': now,
        });
      }
    });
  }

  static Future<void> history(String u, String q) async {
    final d = await db;
    final now = DateTime.now().toUtc().toIso8601String();
    await d.transaction((txn) async {
      await txn.insert('history', {
        'user_id': u,
        'query': q,
        'searched_at': now,
      });
      if (u != 'invitado') {
        await txn.insert('pending_ops', {
          'id': _operationId(),
          'user_id': u,
          'type': 'history',
          'payload': jsonEncode({'query': q}),
          'created_at': now,
        });
      }
    });
  }

  static String _operationId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  static Map<String, Object?> _syncData(Book b) => {
    'title': b.title,
    'authors': b.authors,
    'year': b.year,
    'subjects': b.subjects,
    'cover_id': b.coverId,
  };
  static Future<List<Map<String, dynamic>>> pendingOps(String user) async =>
      (await (await db).query(
            'pending_ops',
            where: 'user_id=?',
            whereArgs: [user],
            orderBy: 'created_at ASC',
          ))
          .map(
            (row) => <String, dynamic>{
              'id': row['id'],
              'type': row['type'],
              'payload': jsonDecode(row['payload'] as String),
              'created_at': row['created_at'],
            },
          )
          .toList();
  static Future<void> acknowledgeOps(List<String> ids) async {
    if (ids.isEmpty) return;
    final d = await db;
    final batch = d.batch();
    for (final id in ids) {
      batch.delete('pending_ops', where: 'id=?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> applyServerSnapshot(
    String u,
    Map<String, dynamic> snapshot,
  ) async {
    final d = await db;
    final books = (snapshot['books'] as List? ?? const []).whereType<Map>().map(
      (raw) {
        final item = Map<String, dynamic>.from(raw);
        return Book(
          key: (item['key'] ?? '').toString(),
          title: (item['title'] ?? 'Sin título').toString(),
          authors: (item['authors'] ?? '').toString(),
          year: (item['year'] ?? '—').toString(),
          subjects: (item['subjects'] is List
              ? (item['subjects'] as List).map((e) => e.toString()).toList()
              : <String>[]),
          coverId: item['cover_id'] is int ? item['cover_id'] as int : null,
        );
      },
    ).toList();
    await cache(books);
    await d.transaction((txn) async {
      await txn.delete('favorites', where: 'user_id=?', whereArgs: [u]);
      for (final key in (snapshot['favorites'] as List? ?? const [])) {
        await txn.insert('favorites', {
          'user_id': u,
          'book_key': key.toString(),
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await txn.delete('history', where: 'user_id=?', whereArgs: [u]);
      for (final entry
          in (snapshot['history'] as List? ?? const []).whereType<Map>()) {
        final item = Map<String, dynamic>.from(entry);
        await txn.insert('history', {
          'user_id': u,
          'query': item['query'],
          'searched_at': item['searched_at'],
        });
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'last_sync',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  static Future<void> selfCheck() async {
    final d = await db;
    const probe = '_local_install_check';
    await d.execute(
      'CREATE TABLE IF NOT EXISTS diagnostics (id TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await d.insert('diagnostics', {
      'id': probe,
      'value': 'ok',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final result = await d.query(
      'diagnostics',
      where: 'id=?',
      whereArgs: [probe],
    );
    await d.delete('diagnostics', where: 'id=?', whereArgs: [probe]);
    if (result.length != 1 || result.single['value'] != 'ok') {
      throw StateError('SQLite no superó su autocomprobación');
    }
  }

  static Future<List<Map<String, Object?>>> searches(String u) async =>
      (await (await db).query(
        'history',
        where: 'user_id=?',
        whereArgs: [u],
        orderBy: 'id DESC',
        limit: 30,
      ));
}

class LibraryApi {
  static Future<List<Book>> search(String q) async {
    final res = await http
        .get(
          Uri.https('openlibrary.org', '/search.json', {
            'q': q,
            'limit': '30',
            'fields':
                'key,title,author_name,first_publish_year,subject,cover_i',
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) {
      throw Exception('Open Library respondió ${res.statusCode}');
    }
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is! Map || json['docs'] is! List) {
      throw const FormatException('Respuesta JSON inesperada');
    }
    return (json['docs'] as List)
        .whereType<Map<String, dynamic>>()
        .map(Book.fromJson)
        .toList();
  }

  static Future<void> healthCheck() async {
    final res = await http
        .get(
          Uri.https('openlibrary.org', '/search.json', {
            'q': 'flutter',
            'limit': '1',
            'fields': 'key',
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw Exception('Open Library respondió ${res.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map || decoded['docs'] is! List) {
      throw const FormatException('JSON inválido');
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await BackendApi.initializeGoogle();
  } catch (_) {
    /* diagnostics report missing platform setup */
  }
  runApp(const PracticaApp());
}

class PracticaApp extends StatelessWidget {
  const PracticaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Biblioteca ESCOM',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: teal,
        surface: const Color(0xFFF7F8F6),
      ),
      scaffoldBackgroundColor: const Color(0xFFF7F8F6),
      fontFamily: 'Arial',
    ),
    home: const LibraryHome(),
  );
}

class LibraryHome extends StatefulWidget {
  const LibraryHome({super.key});
  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  int tab = 0;
  String user = 'invitado';
  bool loading = false, online = true;
  int? lastSearchMs;
  String? error;
  List<Book> results = [], saved = [], cachedBooks = [];
  List<Map<String, Object?>> history = [];
  bool _wasOnline = true;
  bool _syncing = false;
  bool _syncAgain = false;
  bool _healthOk = false;
  int _retrySeconds = 15;
  Timer? _syncRetry;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySub;
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _installSelfCheck());
    _load();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((v) {
      if (mounted) {
        final nowOnline = !v.contains(ConnectivityResult.none);
        final reconnected = nowOnline && !_wasOnline;
        _wasOnline = nowOnline;
        setState(() => online = nowOnline);
        if (reconnected) {
          _load();
          SharedPreferences.getInstance().then((prefs) {
            final lastQuery = prefs.getString('last_query');
            if (lastQuery != null && lastQuery.isNotEmpty) {
              _refreshLastSearch(lastQuery);
            }
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _syncRetry?.cancel();
    _connectivitySub.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> _installSelfCheck() async {
    var localOk = false;
    try {
      await LocalStore.selfCheck();
      await AuthSession.selfCheck();
      localOk = true;
    } catch (_) {
      localOk = false;
    }
    if (!mounted) return;
    setState(() => _healthOk = localOk);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'install_check_at',
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final session = await AuthSession.restore();
    user = session?['email'] ?? prefs.getString('user') ?? 'invitado';
    final vals = await Connectivity().checkConnectivity();
    online = !vals.contains(ConnectivityResult.none);
    saved = await LocalStore.favorites(user);
    cachedBooks = await LocalStore.cached();
    history = await LocalStore.searches(user);
    if (mounted) setState(() {});
    if (online && await AuthSession.token() != null) _sync();
  }

  Future<void> _sync() async {
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    if (!online) return;
    final syncUser = user;
    final sessionToken = await AuthSession.token();
    if (sessionToken == null) return;
    _syncing = true;
    _syncRetry?.cancel();
    var succeeded = false;
    if (mounted) setState(() {});
    try {
      final operations = await LocalStore.pendingOps(syncUser);
      final snapshot = await BackendApi.sync(
        operations,
        sessionToken: sessionToken,
      );
      await LocalStore.applyServerSnapshot(syncUser, snapshot);
      await LocalStore.acknowledgeOps(
        operations.map((e) => e['id'].toString()).toList(),
      );
      _healthOk = true;
      succeeded = true;
      _retrySeconds = 15;
    } catch (_) {
      _healthOk = false;
      _syncRetry?.cancel();
      _syncRetry = Timer(Duration(seconds: _retrySeconds), () {
        _retrySeconds = (_retrySeconds * 2).clamp(15, 300);
        if (mounted) _sync();
      });
    } finally {
      _syncing = false;
      await _loadLocalOnly();
    }
    final runAgain = _syncAgain;
    _syncAgain = false;
    if (runAgain && mounted) {
      _syncRetry?.cancel();
      _syncRetry = Timer(const Duration(milliseconds: 250), () {
        if (mounted) _sync();
      });
    } else if (succeeded &&
        mounted &&
        (await LocalStore.pendingOps(syncUser)).isNotEmpty) {
      _syncRetry?.cancel();
      _syncRetry = Timer(const Duration(milliseconds: 250), () {
        if (mounted) _sync();
      });
    }
  }

  Future<void> _loadLocalOnly() async {
    saved = await LocalStore.favorites(user);
    cachedBooks = await LocalStore.cached();
    history = await LocalStore.searches(user);
    if (mounted) setState(() {});
  }

  Future<void> _search(String value) async {
    final q = value.trim();
    if (q.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_query', q);
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      loading = true;
      error = null;
    });
    await LocalStore.history(user, q);
    final timer = Stopwatch()..start();
    try {
      final list = await LibraryApi.search(q);
      timer.stop();
      lastSearchMs = timer.elapsedMilliseconds;
      await LocalStore.cache(list);
      if (mounted) setState(() => results = list);
    } catch (e) {
      timer.stop();
      lastSearchMs = timer.elapsedMilliseconds;
      final cached = await LocalStore.cached();
      final matches = cached
          .where(
            (b) => ('${b.title} ${b.authors}').toLowerCase().contains(
              q.toLowerCase(),
            ),
          )
          .toList();
      if (mounted) {
        setState(() {
          results = matches;
          error = matches.isEmpty
              ? 'No se pudo conectar. Intenta de nuevo cuando tengas Internet.'
              : 'Sin conexión: mostrando coincidencias guardadas.';
        });
      }
    } finally {
      await _load();
      if (online && await AuthSession.token() != null) _sync();
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _refreshLastSearch(String value) async {
    final q = value.trim();
    if (q.isEmpty || !mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    final timer = Stopwatch()..start();
    try {
      final list = await LibraryApi.search(q);
      timer.stop();
      lastSearchMs = timer.elapsedMilliseconds;
      await LocalStore.cache(list);
      if (mounted) setState(() => results = list);
    } catch (_) {
      timer.stop();
      lastSearchMs = timer.elapsedMilliseconds;
      final cached = await LocalStore.cached();
      final matches = cached
          .where(
            (book) =>
                ('${book.title} ${book.authors} ${book.subjects.join(' ')}')
                    .toLowerCase()
                    .contains(q.toLowerCase()),
          )
          .toList();
      if (mounted) {
        setState(() {
          results = matches;
          error = matches.isEmpty
              ? 'No se pudo actualizar la búsqueda.'
              : 'Sin conexión: mostrando coincidencias guardadas.';
        });
      }
    } finally {
      await _load();
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _favorite(Book b) async {
    await LocalStore.toggle(user, b);
    await _load();
    setState(() {});
    if (online && await AuthSession.token() != null) _sync();
  }

  Future<void> _account() async {
    final session = await AuthSession.restore();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountPage(
          session: session,
          onAuthenticated: (response) async {
            await AuthSession.save(response);
            await _load();
            await _sync();
          },
          onSignOut: () async {
            await AuthSession.clear();
            await _load();
          },
          onSync: _sync,
          onOpenAdmin: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AdminActivityPage())),
          onOpenLibrary: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ServerLibraryPage(books: results),
            ),
          ),
          onOpenDiagnostics: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const DiagnosticsPage())),
        ),
      ),
    );
    await _load();
  }

  List<Book> get recommendations {
    final unique = <String, Book>{
      for (final b in [...cachedBooks, ...saved, ...results]) b.key: b,
    };
    final source = unique.values.toList();
    final subjects = <String, int>{};
    for (final b in source) {
      for (final s in b.subjects) {
        subjects[s] = (subjects[s] ?? 0) + 1;
      }
    }
    final sorted =
        source.where((b) => !saved.any((f) => f.key == b.key)).toList()
          ..sort((a, b) => _score(b, subjects).compareTo(_score(a, subjects)));
    return sorted.take(10).toList();
  }

  int _score(Book b, Map<String, int> s) =>
      b.subjects.fold(0, (a, x) => a + (s[x] ?? 0));
  @override
  Widget build(BuildContext context) {
    final titles = ['Buscar libros', 'Favoritos', 'Recomendados', 'Actividad'];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          titles[tab],
          style: const TextStyle(fontWeight: FontWeight.w800, color: ink),
        ),
        actions: [
          Icon(
            online ? Icons.cloud_done : Icons.cloud_off,
            color: online ? teal : Colors.orange,
          ),
          IconButton(
            tooltip: 'Diagnóstico local y servicios',
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DiagnosticsPage())),
            icon: Icon(
              _healthOk
                  ? Icons.check_circle_outline
                  : Icons.health_and_safety_outlined,
              color: teal,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Cuenta',
            onPressed: _account,
            icon: const Icon(Icons.account_circle_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: tab,
          children: [
            _searchView(),
            _bookList(saved, 'Aún no tienes favoritos'),
            _bookList(
              recommendations,
              saved.isEmpty && results.isEmpty
                  ? 'Busca un libro o guarda favoritos para recibir sugerencias'
                  : 'No encontramos más sugerencias',
            ),
            _historyView(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'Buscar'),
          NavigationDestination(
            icon: Icon(Icons.bookmark_outline),
            label: 'Favoritos',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            label: 'Para ti',
          ),
          NavigationDestination(icon: Icon(Icons.history), label: 'Historial'),
        ],
      ),
    );
  }

  Widget _searchView() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Encuentra tu próxima lectura',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: ink,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: search,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: 'Título, autor o tema',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  onPressed: () => _search(search.text),
                  icon: const Icon(Icons.arrow_forward),
                ),
                filled: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(
                    color: error!.startsWith('Sin conexión')
                        ? teal
                        : Colors.red.shade700,
                  ),
                ),
              ),
          ],
        ),
      ),
      if (loading) const LinearProgressIndicator(color: teal),
      if (lastSearchMs != null && results.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${results.length} resultados · ${(lastSearchMs! / 1000).toStringAsFixed(2)} s',
              style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade600),
            ),
          ),
        ),
      Expanded(
        child: results.isEmpty && !loading
            ? _empty(
                'Busca libros en Open Library. Tus consultas y favoritos se guardan en este dispositivo.',
              )
            : _bookList(results, 'No se encontraron libros'),
      ),
    ],
  );
  Widget _bookList(List<Book> books, String empty) => books.isEmpty
      ? _empty(empty)
      : ListView.builder(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
          itemCount: books.length,
          itemBuilder: (ctx, i) => _bookCard(books[i]),
        );
  Widget _bookCard(Book b) => Card(
    margin: const EdgeInsets.symmetric(vertical: 6),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _detail(b),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: b.coverId == null
                  ? Container(
                      width: 66,
                      height: 96,
                      color: const Color(0xFFE7ECE9),
                      child: const Icon(
                        Icons.menu_book_outlined,
                        color: teal,
                        size: 32,
                      ),
                    )
                  : Image.network(
                      'https://covers.openlibrary.org/b/id/${b.coverId}-M.jpg',
                      width: 66,
                      height: 96,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 66,
                        height: 96,
                        color: const Color(0xFFE7ECE9),
                        child: const Icon(
                          Icons.menu_book_outlined,
                          color: teal,
                          size: 32,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: ink,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    b.authors.isEmpty ? 'Autor desconocido' : b.authors,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.blueGrey.shade700),
                  ),
                  Text(
                    'Publicado: ${b.year}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blueGrey.shade500,
                    ),
                  ),
                  if (b.subjects.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        b.subjects.take(2).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.blueGrey.shade500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            FutureBuilder<bool>(
              future: LocalStore.isFavorite(user, b.key),
              builder: (c, s) => IconButton(
                tooltip: 'Guardar favorito',
                onPressed: () => _favorite(b),
                icon: Icon(
                  s.data == true ? Icons.bookmark : Icons.bookmark_add_outlined,
                  color: teal,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  void _detail(Book b) => showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.all(24),
      child: Wrap(
        children: [
          Text(
            b.title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Autor: ${b.authors.isEmpty ? 'Desconocido' : b.authors}\nPrimera publicación: ${b.year}\n\nTemas: ${b.subjects.isEmpty ? 'Sin categorías' : b.subjects.join(', ')}',
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _favorite(b);
            },
            icon: const Icon(Icons.bookmark_add_outlined),
            label: const Text('Cambiar favorito'),
          ),
        ],
      ),
    ),
  );
  Widget _historyView() {
    if (history.isEmpty) {
      return _empty(
        'Tus búsquedas aparecerán aquí y estarán disponibles sin conexión.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Cuenta: $user',
          style: const TextStyle(color: ink, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        for (final h in history)
          ListTile(
            leading: const Icon(Icons.manage_search, color: teal),
            title: Text(h['query'] as String),
            subtitle: Text(
              (h['searched_at'] as String)
                  .replaceFirst('T', ' ')
                  .split('.')
                  .first,
            ),
            onTap: () {
              search.text = h['query'] as String;
              setState(() => tab = 0);
              _search(search.text);
            },
          ),
      ],
    );
  }

  Widget _empty(String msg) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.auto_stories_outlined, size: 48, color: teal),
          const SizedBox(height: 12),
          Text(
            msg,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.blueGrey.shade600),
          ),
        ],
      ),
    ),
  );
}

typedef AuthHandler = Future<void> Function(Map<String, dynamic> response);

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.session,
    required this.onAuthenticated,
    required this.onSignOut,
    required this.onSync,
    required this.onOpenAdmin,
    required this.onOpenLibrary,
    required this.onOpenDiagnostics,
  });
  final Map<String, String>? session;
  final AuthHandler onAuthenticated;
  final Future<void> Function() onSignOut, onSync;
  final VoidCallback onOpenAdmin, onOpenLibrary, onOpenDiagnostics;
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final email = TextEditingController(),
      name = TextEditingController(),
      password = TextEditingController();
  bool register = false, busy = false;
  late bool signedIn;
  String? error;

  @override
  void initState() {
    super.initState();
    signedIn = widget.session != null;
  }

  Future<void> _submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final response = register
          ? await BackendApi.register(
              email.text.trim(),
              password.text,
              name.text.trim(),
            )
          : await BackendApi.login(email.text.trim(), password.text);
      await widget.onAuthenticated(response);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _google() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final response = await BackendApi.signInWithGoogle();
      await widget.onAuthenticated(response);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = signedIn ? widget.session : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Cuenta y sincronización')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (session != null) ...[
            CircleAvatar(
              radius: 30,
              child: Text(
                (session['name'] ?? session['email'] ?? '?')
                    .substring(0, 1)
                    .toUpperCase(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              session['name'] ?? '',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(session['email'] ?? '', textAlign: TextAlign.center),
            Text(
              'Rol: ${session['role'] ?? 'usuario'}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      await widget.onSync();
                      if (mounted) setState(() => busy = false);
                    },
              icon: const Icon(Icons.sync),
              label: const Text('Sincronizar ahora'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await widget.onSignOut();
                if (mounted) setState(() => signedIn = false);
              },
              icon: const Icon(Icons.logout),
              label: const Text('Cerrar sesión'),
            ),
            const Divider(height: 30),
            ListTile(
              leading: const Icon(Icons.library_books_outlined),
              title: const Text('Mi colección en el servidor'),
              subtitle: const Text('Consultar y editar registros CRUD'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenLibrary,
            ),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Actividad de usuarios (admin)'),
              subtitle: const Text(
                'El backend valida el rol y puede denegar el acceso',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenAdmin,
            ),
          ] else ...[
            const Icon(Icons.menu_book, size: 52, color: teal),
            const SizedBox(height: 12),
            Text(
              register ? 'Crear cuenta' : 'Iniciar sesión',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            if (register)
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  border: OutlineInputBorder(),
                ),
              ),
            if (register) const SizedBox(height: 12),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                labelText: 'Correo',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autofillHints: [
                register ? AutofillHints.newPassword : AutofillHints.password,
              ],
              decoration: const InputDecoration(
                labelText: 'Contraseña (mínimo 8 caracteres)',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : _submit,
              child: busy
                  ? const CircularProgressIndicator()
                  : Text(register ? 'Crear cuenta' : 'Entrar'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      register = !register;
                      error = null;
                    }),
              child: Text(register ? 'Ya tengo cuenta' : 'Crear cuenta'),
            ),
            const Divider(height: 28),
            OutlinedButton.icon(
              onPressed: busy || !BackendApi.googleConfigured ? null : _google,
              icon: const Icon(Icons.g_mobiledata, size: 28),
              label: const Text('Continuar con Google'),
            ),
            if (!BackendApi.googleConfigured)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Google requiere IDs OAuth de la app en Google Cloud. El inicio con correo sí funciona.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Continuar como invitado'),
            ),
          ],
          if (session != null) ...[
            const Divider(height: 28),
            ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('Autocomprobación del dispositivo'),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenDiagnostics,
            ),
          ],
        ],
      ),
    );
  }
}

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key});
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  bool running = false;
  Map<String, String> results = {};
  String? lastSync;
  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      running = true;
      results = {};
    });
    final out = <String, String>{};
    bool backendGoogleConfigured = false;
    Future<void> check(String title, Future<void> Function() task) async {
      try {
        await task();
        out[title] = 'correcto';
      } catch (e) {
        out[title] = 'no disponible: $e';
      }
    }

    await check(
      'Base SQLite local (lectura y escritura)',
      LocalStore.selfCheck,
    );
    await check('Almacenamiento seguro de sesión', AuthSession.selfCheck);
    try {
      final states = await Connectivity().checkConnectivity();
      out['Conectividad del dispositivo'] =
          states.contains(ConnectivityResult.none)
          ? 'sin conexión; modo offline disponible'
          : 'conectado';
    } catch (e) {
      out['Conectividad del dispositivo'] = 'no disponible: $e';
    }
    await check('API pública Open Library (HTTPS)', LibraryApi.healthCheck);
    await check('Backend REST y base de datos', () async {
      final data = await BackendApi.health();
      backendGoogleConfigured = data['google_configured'] == true;
      if (data['status'] != 'ok' || data['database'] != 'ok') {
        throw StateError('estado backend inválido');
      }
    });
    out['Google OAuth'] = BackendApi.googleConfigured
        ? backendGoogleConfigured
              ? 'IDs de app y backend configurados; valida login real'
              : 'ID de backend ausente en .env'
        : 'pendiente de IDs OAuth de Android/iOS';
    final prefs = await SharedPreferences.getInstance();
    lastSync = prefs.getString('last_sync');
    if (mounted) {
      setState(() {
        results = out;
        running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Autocomprobación local'),
      actions: [
        IconButton(
          onPressed: running ? null : _run,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Se ejecuta al abrir esta pantalla. Los fallos de servidor o Internet no bloquean la app ni borran tus datos locales.',
          style: TextStyle(color: ink),
        ),
        const SizedBox(height: 12),
        if (running) const LinearProgressIndicator(color: teal),
        for (final entry in results.entries)
          ListTile(
            leading: Icon(
              entry.value == 'correcto' ||
                      entry.value == 'conectado' ||
                      entry.value.startsWith('IDs')
                  ? Icons.check_circle
                  : entry.value.startsWith('sin conexión')
                  ? Icons.cloud_off
                  : Icons.info_outline,
              color:
                  entry.value == 'correcto' ||
                      entry.value == 'conectado' ||
                      entry.value.startsWith('IDs')
                  ? teal
                  : Colors.orange,
            ),
            title: Text(entry.key),
            subtitle: Text(entry.value),
          ),
        ListTile(
          leading: const Icon(Icons.update),
          title: const Text('Última sincronización'),
          subtitle: Text(lastSync ?? 'Todavía no sincronizado con una cuenta'),
        ),
        const SizedBox(height: 12),
        SelectableText(
          'Backend: ${BackendApi.baseUrl}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );
}

class AdminActivityPage extends StatefulWidget {
  const AdminActivityPage({super.key});
  @override
  State<AdminActivityPage> createState() => _AdminActivityPageState();
}

class _AdminActivityPageState extends State<AdminActivityPage> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> users = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      users = await BackendApi.adminActivity();
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Actividad de usuarios'),
      actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    error!.contains('403') || error!.contains('administrador')
                        ? Icons.lock_outline
                        : Icons.cloud_off,
                    size: 42,
                    color: Colors.orange,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    error!.contains('403') || error!.contains('administrador')
                        ? 'Acceso denegado por el backend. Solo un administrador puede consultar datos de otras cuentas.'
                        : error!,
                    textAlign: TextAlign.center,
                  ),
                  TextButton(onPressed: _load, child: const Text('Reintentar')),
                ],
              ),
            ),
          )
        : users.isEmpty
        ? const Center(child: Text('Sin cuentas registradas'))
        : ListView(
            children: [
              for (final user in users)
                ExpansionTile(
                  leading: Icon(
                    user['role'] == 'admin'
                        ? Icons.admin_panel_settings
                        : Icons.person_outline,
                    color: teal,
                  ),
                  title: Text(
                    user['name']?.toString() ?? user['email'].toString(),
                  ),
                  subtitle: Text('${user['email']} · ${user['role']}'),
                  children: [
                    ListTile(
                      title: const Text('Favoritos'),
                      subtitle: Text(
                        ((user['favorites'] as List?) ?? const [])
                                .join(', ')
                                .isEmpty
                            ? 'Sin favoritos'
                            : ((user['favorites'] as List).join(', ')),
                      ),
                    ),
                    for (final entry in (user['history'] as List? ?? const []))
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.history),
                        title: Text(entry['query'].toString()),
                        subtitle: Text(entry['searched_at'].toString()),
                      ),
                  ],
                ),
            ],
          ),
  );
}

class ServerLibraryPage extends StatefulWidget {
  const ServerLibraryPage({super.key, required this.books});
  final List<Book> books;
  @override
  State<ServerLibraryPage> createState() => _ServerLibraryPageState();
}

class _ServerLibraryPageState extends State<ServerLibraryPage> {
  bool loading = true, working = false;
  String? error;
  List<Map<String, dynamic>> items = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      items = await BackendApi.serverBooks();
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _add(Book book) async {
    setState(() => working = true);
    try {
      await BackendApi.createBook(book.key, book.toServerData());
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _edit(Map<String, dynamic> item) async {
    final title = TextEditingController(text: item['title']?.toString() ?? '');
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Editar libro (PUT)'),
        content: TextField(
          controller: title,
          decoration: const InputDecoration(labelText: 'Título'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, title.text.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (updated == null || updated.isEmpty) return;
    setState(() => working = true);
    try {
      final data = Map<String, dynamic>.from(item)..['title'] = updated;
      data.remove('id');
      data.remove('key');
      data.remove('updated_at');
      await BackendApi.updateBook(item['id'] as int, data);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    setState(() => working = true);
    try {
      await BackendApi.deleteBook(item['id'] as int);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Colección REST CRUD'),
      actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))],
    ),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'La colección pertenece a tu cuenta. GET carga registros; POST agrega, PUT edita y DELETE elimina en el backend.',
                style: TextStyle(color: ink),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              if (widget.books.isNotEmpty) ...[
                const Text('Agregar desde los resultados de búsqueda'),
                for (final book in widget.books.take(8))
                  ListTile(
                    dense: true,
                    title: Text(
                      book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(book.authors),
                    trailing: IconButton(
                      onPressed: working ? null : () => _add(book),
                      icon: const Icon(Icons.add_circle_outline, color: teal),
                    ),
                  ),
              ],
              const Divider(),
              const Text('Registros guardados en el servidor'),
              if (items.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Colección vacía'),
                ),
              for (final item in items)
                Card(
                  child: ListTile(
                    title: Text(item['title']?.toString() ?? 'Sin título'),
                    subtitle: Text(item['authors']?.toString() ?? ''),
                    trailing: Wrap(
                      spacing: 0,
                      children: [
                        IconButton(
                          tooltip: 'Editar (PUT)',
                          onPressed: working ? null : () => _edit(item),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: 'Eliminar (DELETE)',
                          onPressed: working ? null : () => _delete(item),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
  );
}
