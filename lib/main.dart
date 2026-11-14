import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

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
  static Future<Database> get db async => _db ??= await openDatabase(
    p.join(await getDatabasesPath(), 'practica5.db'),
    version: 1,
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
    },
  );
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
    await cache([b]);
    final d = await db;
    if (await isFavorite(u, b.key)) {
      await d.delete(
        'favorites',
        where: 'user_id=? AND book_key=?',
        whereArgs: [u, b.key],
      );
    } else {
      await d.insert('favorites', {
        'user_id': u,
        'book_key': b.key,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  static Future<void> history(String u, String q) async => (await db).insert(
    'history',
    {'user_id': u, 'query': q, 'searched_at': DateTime.now().toIso8601String()},
  );
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
}

void main() => runApp(const PracticaApp());

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
  String? error;
  List<Book> results = [], saved = [];
  List<Map<String, Object?>> history = [];
  bool _wasOnline = true;
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    _load();
    Connectivity().onConnectivityChanged.listen((v) {
      if (mounted) {
        final nowOnline = !v.contains(ConnectivityResult.none);
        final reconnected = nowOnline && !_wasOnline;
        _wasOnline = nowOnline;
        setState(() => online = nowOnline);
        if (reconnected) {
          _load();
          SharedPreferences.getInstance().then((prefs) {
            final lastQuery = prefs.getString('last_query');
            if (lastQuery != null && lastQuery.isNotEmpty) _search(lastQuery);
          });
        }
      }
    });
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    user = prefs.getString('user') ?? 'invitado';
    final vals = await Connectivity().checkConnectivity();
    online = !vals.contains(ConnectivityResult.none);
    saved = await LocalStore.favorites(user);
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
    try {
      final list = await LibraryApi.search(q);
      await LocalStore.cache(list);
      if (mounted) setState(() => results = list);
    } catch (e) {
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
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _favorite(Book b) async {
    await LocalStore.toggle(user, b);
    await _load();
    setState(() {});
  }

  Future<void> _signIn() async {
    final c = TextEditingController(
      text: user == 'invitado' ? 'alumno@escom.ipn.mx' : user,
    );
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sesión local'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(
            labelText: 'Correo o nombre de usuario',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              final p = await SharedPreferences.getInstance();
              await p.setString(
                'user',
                c.text.trim().isEmpty ? 'invitado' : c.text.trim(),
              );
              if (ctx.mounted) Navigator.pop(ctx);
              await _load();
            },
            child: const Text('Continuar'),
          ),
        ],
      ),
    );
  }

  List<Book> get recommendations {
    final source = [...saved, ...results];
    final subjects = <String, int>{};
    for (final b in source) {
      for (final s in b.subjects) {
        subjects[s] = (subjects[s] ?? 0) + 1;
      }
    }
    final sorted =
        source.where((b) => !saved.any((f) => f.key == b.key)).toList()
          ..sort((a, b) => _score(b, subjects).compareTo(_score(a, subjects)));
    return sorted.toSet().take(10).toList();
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
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Cuenta',
            onPressed: _signIn,
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
