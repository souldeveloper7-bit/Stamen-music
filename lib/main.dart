import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String apiBaseUrl = 'https://jiosavanapiryden.vercel.app/api';
const Color bg = Color(0xFF090B0F);
const Color panel = Color(0xFF151922);
const Color accent = Color(0xFF1ED760);

late final StamenAudioHandler audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  audioHandler = await AudioService.init(
    builder: () => StamenAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.stamen.music.playback',
      androidNotificationChannelName: 'Stamen music playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: false,
    ),
  );
  runApp(const StamenApp());
}

class Song {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String artwork;
  final int duration;
  final String streamUrl;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.artwork = '',
    this.duration = 0,
    this.streamUrl = '',
  });

  factory Song.fromSearch(Map<String, dynamic> json) {
    final artists = json['artists'];
    String artist = '';
    if (artists is Map && artists['primary'] is List) {
      artist = (artists['primary'] as List)
          .map((e) => e is Map ? (e['name'] ?? '').toString() : '')
          .where((e) => e.isNotEmpty)
          .join(', ');
    }
    final images = json['image'];
    String artwork = '';
    if (images is List && images.isNotEmpty) {
      final last = images.last;
      if (last is Map) artwork = (last['url'] ?? '').toString();
    } else if (json['image'] is String) {
      artwork = json['image'].toString();
    }
    return Song(
      id: (json['id'] ?? '').toString(),
      title: _clean((json['name'] ?? 'Unknown song').toString()),
      artist: artist.isEmpty ? 'Unknown artist' : artist,
      album: _clean((json['album'] is Map ? json['album']['name'] : '')?.toString() ?? ''),
      artwork: artwork,
      duration: int.tryParse((json['duration'] ?? 0).toString()) ?? 0,
    );
  }

  factory Song.fromJson(Map<String, dynamic> json) => Song(
    id: (json['id'] ?? '').toString(),
    title: json['title'] ?? 'Unknown song',
    artist: json['artist'] ?? 'Unknown artist',
    album: json['album'] ?? '',
    artwork: json['artwork'] ?? '',
    duration: json['duration'] ?? 0,
    streamUrl: json['streamUrl'] ?? '',
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'title': title, 'artist': artist, 'album': album,
    'artwork': artwork, 'duration': duration, 'streamUrl': streamUrl,
  };

  static String _clean(String value) =>
      value.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&amp;', '&').trim();
}

class MusicApi {
  final http.Client client;
  MusicApi({http.Client? client}) : client = client ?? http.Client();

  Future<List<Song>> search(String query) async {
    final uri = Uri.parse('$apiBaseUrl/search/songs').replace(queryParameters: {
      'query': query, 'page': '0', 'limit': '25',
    });
    final response = await client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Search API returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['success'] != true) {
      throw Exception('The music API did not return a successful search response.');
    }
    final data = decoded['data'];
    final rows = data is Map && data['results'] is List ? data['results'] as List : <dynamic>[];
    return rows.whereType<Map>().map((e) => Song.fromSearch(Map<String, dynamic>.from(e)))
        .where((s) => s.id.isNotEmpty).toList();
  }

  Future<Song> resolveSong(Song song) async {
    final uri = Uri.parse('$apiBaseUrl/songs/${Uri.encodeComponent(song.id)}');
    final response = await client.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Song details API returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['success'] != true || decoded['data'] is! List ||
        (decoded['data'] as List).isEmpty) {
      throw Exception('Song details were not found.');
    }
    final info = Map<String, dynamic>.from(decoded['data'][0] as Map);
    final links = info['downloadUrl'];
    if (links is! List || links.isEmpty) {
      throw Exception('No playable audio URL was supplied by the API.');
    }
    // The API sample returns quality options in downloadUrl. Prefer the final entry,
    // matching the behaviour of the supplied Python example.
    final chosen = links.last;
    if (chosen is! Map || (chosen['url'] ?? '').toString().isEmpty) {
      throw Exception('The API returned an invalid audio URL.');
    }
    final primary = info['artists'] is Map && info['artists']['primary'] is List
        ? (info['artists']['primary'] as List)
            .map((e) => e is Map ? (e['name'] ?? '').toString() : '')
            .where((e) => e.isNotEmpty).join(', ')
        : song.artist;
    String art = song.artwork;
    final images = info['image'];
    if (images is List && images.isNotEmpty && images.last is Map) {
      art = (images.last['url'] ?? art).toString();
    }
    return Song(
      id: song.id,
      title: (info['name'] ?? song.title).toString().replaceAll(RegExp(r'<[^>]*>'), ''),
      artist: primary.isEmpty ? song.artist : primary,
      album: (info['album'] is Map ? info['album']['name'] : song.album)?.toString() ?? song.album,
      artwork: art,
      duration: int.tryParse((info['duration'] ?? song.duration).toString()) ?? song.duration,
      streamUrl: chosen['url'].toString(),
    );
  }
}

class StamenAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<PlaybackEvent>? _eventSub;
  StreamSubscription<PlayerState>? _stateSub;
  final StreamController<Duration?> _positionController = StreamController<Duration?>.broadcast();

  StamenAudioHandler() {
    _eventSub = _player.playbackEventStream.listen((event) {
      playbackState.add(_state(event));
    });
    _player.positionStream.listen((position) => _positionController.add(position));
    _stateSub = _player.playerStateStream.listen((state) {
      playbackState.add(_state(_player.playbackEvent));
    });
  }

  PlaybackState _state(PlaybackEvent event) => PlaybackState(
    controls: [
      MediaControl.skipToPrevious,
      if (_player.playing) MediaControl.pause else MediaControl.play,
      MediaControl.skipToNext,
      MediaControl.stop,
    ],
    systemActions: const {MediaAction.seek},
    androidCompactActionIndices: const [0, 1, 2],
    processingState: const {
      ProcessingState.idle: AudioProcessingState.idle,
      ProcessingState.loading: AudioProcessingState.loading,
      ProcessingState.buffering: AudioProcessingState.buffering,
      ProcessingState.ready: AudioProcessingState.ready,
      ProcessingState.completed: AudioProcessingState.completed,
    }[_player.processingState]!,
    playing: _player.playing,
    updatePosition: _player.position,
    bufferedPosition: _player.bufferedPosition,
    speed: _player.speed,
    queueIndex: 0,
  );

  Future<void> playSong(Song song) async {
    if (song.streamUrl.isEmpty) throw Exception('This song has no stream URL.');
    mediaItem.add(MediaItem(
      id: song.id, title: song.title, artist: song.artist, album: song.album,
      artUri: song.artwork.isEmpty ? null : Uri.tryParse(song.artwork),
      duration: Duration(seconds: song.duration),
    ));
    await _player.setAudioSource(AudioSource.uri(Uri.parse(song.streamUrl)));
    await _player.play();
  }

  Future<void> playLocalFile(String path, String title) async {
    mediaItem.add(MediaItem(id: path, title: title, artist: 'On this device'));
    await _player.setAudioSource(AudioSource.file(path));
    await _player.play();
  }

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> stop() async {
    await _player.stop();
    await super.stop();
  }
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> skipToNext() async {}
  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> onTaskRemoved() async {
    await _player.stop();
    await super.onTaskRemoved();
  }

  Stream<Duration?> get positionStream => _positionController.stream;

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _stateSub?.cancel();
    await _positionController.close();
    await _player.dispose();
  }
}

class StamenApp extends StatelessWidget {
  const StamenApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'stamen',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
      useMaterial3: true,
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: Colors.white),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final MusicApi api = MusicApi();
  final TextEditingController searchController = TextEditingController();
  int tab = 0;
  bool loading = false;
  String? error;
  List<Song> results = [];
  List<Song> favourites = [];
  List<Song> localFiles = [];
  Song? current;
  final List<String> quickSearches = ['Arijit Singh', 'A.R. Rahman', 'Taylor Swift', 'Imagine Dragons'];

  @override
  void initState() {
    super.initState();
    _loadSaved();
    audioHandler.mediaItem.listen((item) {
      if (!mounted || item == null) return;
      setState(() {
        current = Song(id: item.id, title: item.title, artist: item.artist ?? '',
          album: item.album ?? '', artwork: item.artUri?.toString() ?? '',
          duration: item.duration?.inSeconds ?? 0);
      });
    });
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final fav = prefs.getStringList('favourites') ?? [];
    final local = prefs.getStringList('local_files') ?? [];
    if (!mounted) return;
    setState(() {
      favourites = fav.map((s) => Song.fromJson(Map<String, dynamic>.from(jsonDecode(s)))).toList();
      localFiles = local.map((s) => Song.fromJson(Map<String, dynamic>.from(jsonDecode(s)))).toList();
    });
  }

  Future<void> _saveFavourites() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favourites', favourites.map((s) => jsonEncode(s.toJson())).toList());
  }

  Future<void> _saveLocalFiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('local_files', localFiles.map((s) => jsonEncode(s.toJson())).toList());
  }

  Future<void> search(String query) async {
    if (query.trim().length < 2) return;
    FocusScope.of(context).unfocus();
    setState(() { loading = true; error = null; results = []; tab = 1; });
    try {
      final found = await api.search(query.trim());
      if (!mounted) return;
      setState(() { results = found; if (found.isEmpty) error = 'No songs found. Try another search.'; });
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> playSong(Song song) async {
    try {
      setState(() => error = null);
      final resolved = await api.resolveSong(song);
      await audioHandler.playSong(resolved);
      if (!mounted) return;
      setState(() => current = resolved);
      _showPlayer();
    } catch (e) {
      if (mounted) setState(() => error = 'Could not play this track: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  Future<void> importLocalAudio() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.audio, allowMultiple: true, withData: false,
    );
    if (picked == null) return;
    final additions = <Song>[];
    for (final file in picked.files) {
      final path = file.path;
      if (path == null) continue;
      additions.add(Song(id: path, title: file.name, artist: 'On this device', streamUrl: path));
    }
    setState(() {
      for (final song in additions) {
        if (!localFiles.any((s) => s.id == song.id)) localFiles.add(song);
      }
    });
    await _saveLocalFiles();
  }

  Future<void> playLocal(Song song) async {
    try {
      await audioHandler.playLocalFile(song.id, song.title);
      setState(() => current = song);
      _showPlayer();
    } catch (e) {
      setState(() => error = 'Unable to play local file: $e');
    }
  }

  void toggleFavourite(Song song) {
    setState(() {
      if (favourites.any((s) => s.id == song.id)) {
        favourites.removeWhere((s) => s.id == song.id);
      } else {
        favourites.add(song);
      }
    });
    _saveFavourites();
  }

  bool isFavourite(Song song) => favourites.any((s) => s.id == song.id);

  void _showPlayer() => showModalBottomSheet(
    context: context, isScrollControlled: true, backgroundColor: panel,
    builder: (_) => PlayerSheet(song: current ?? const Song(id: '', title: '', artist: '')),
  );

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _home(),
      _searchPage(),
      _libraryPage(),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.graphic_eq_rounded, color: accent, size: 27),
          SizedBox(width: 8),
          Text('stamen', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: .4)),
        ]),
        actions: [
          IconButton(tooltip: 'Import audio from device', onPressed: importLocalAudio,
            icon: const Icon(Icons.add_to_queue_rounded)),
        ],
      ),
      body: Column(children: [
        Expanded(child: pages[tab]),
        if (error != null) Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(error!, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
        ),
        _miniPlayer(),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (v) => setState(() => tab = v),
        backgroundColor: const Color(0xFF11151C),
        indicatorColor: accent.withOpacity(.16),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
        ],
      ),
    );
  }

  Widget _home() => ListView(
    padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
    children: [
      const Text('Your sound, your space.', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Text('Stream something you love.', style: TextStyle(color: Colors.white.withOpacity(.6))),
      const SizedBox(height: 24),
      _searchBox(),
      const SizedBox(height: 26),
      const Text('QUICK PICKS', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.bold, fontSize: 12)),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: quickSearches.map((q) =>
        ActionChip(label: Text(q), onPressed: () { searchController.text = q; search(q); },
          backgroundColor: panel, side: BorderSide.none)).toList()),
      const SizedBox(height: 26),
      const Text('YOUR LIBRARY', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      _featureTile(Icons.favorite_rounded, 'Liked songs', '${favourites.length} saved tracks', () => setState(() => tab = 2)),
      _featureTile(Icons.folder_rounded, 'On this device', '${localFiles.length} local audio files', () => setState(() => tab = 2)),
      const SizedBox(height: 14),
      Text('Tip: Search a song or artist to start streaming.', style: TextStyle(color: Colors.white.withOpacity(.48))),
    ],
  );

  Widget _searchPage() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      const Text('Find your next favourite', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 16),
      _searchBox(),
      const SizedBox(height: 18),
      if (loading) const Center(child: Padding(
        padding: EdgeInsets.all(28), child: CircularProgressIndicator(color: accent))),
      if (!loading && results.isEmpty && error == null)
        Center(child: Padding(padding: const EdgeInsets.all(28),
          child: Text('Search songs, albums or artists', style: TextStyle(color: Colors.white.withOpacity(.55))))),
      ...results.map(_songTile),
    ],
  );

  Widget _libraryPage() => ListView(
    padding: const EdgeInsets.all(18),
    children: [
      const Text('Your library', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
      const SizedBox(height: 18),
      _featureTile(Icons.favorite, 'Liked songs', '${favourites.length} tracks', () {}),
      ...favourites.map(_songTile),
      const SizedBox(height: 20),
      Row(children: [
        const Expanded(child: Text('Offline on this device', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
        IconButton(onPressed: importLocalAudio, icon: const Icon(Icons.add_circle_outline, color: accent)),
      ]),
      Text('Add audio files you own or are licensed to store offline.',
        style: TextStyle(color: Colors.white.withOpacity(.5), fontSize: 12)),
      const SizedBox(height: 10),
      if (localFiles.isEmpty) Text('No local audio added yet.',
        style: TextStyle(color: Colors.white.withOpacity(.55))),
      ...localFiles.map((s) => _songTile(s, local: true)),
    ],
  );

  Widget _searchBox() => TextField(
    controller: searchController,
    textInputAction: TextInputAction.search,
    onSubmitted: search,
    decoration: InputDecoration(
      hintText: 'What do you want to play?',
      prefixIcon: const Icon(Icons.search, color: accent),
      filled: true, fillColor: panel,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward_rounded),
        onPressed: () => search(searchController.text)),
    ),
  );

  Widget _songTile(Song song, {bool local = false}) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 3),
    leading: _art(song.artwork, size: 52),
    title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w600)),
    subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
      style: TextStyle(color: Colors.white.withOpacity(.55))),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      if (!local) IconButton(
        tooltip: isFavourite(song) ? 'Remove from liked songs' : 'Add to liked songs',
        icon: Icon(isFavourite(song) ? Icons.favorite : Icons.favorite_border,
          color: isFavourite(song) ? accent : Colors.white70),
        onPressed: () => toggleFavourite(song)),
      IconButton(icon: const Icon(Icons.play_circle_fill, color: accent, size: 30),
        onPressed: () => local ? playLocal(song) : playSong(song)),
    ]),
    onTap: () => local ? playLocal(song) : playSong(song),
  );

  Widget _featureTile(IconData icon, String title, String subtitle, VoidCallback onTap) =>
    Card(color: panel, child: ListTile(
      leading: Icon(icon, color: accent), title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle, style: TextStyle(color: Colors.white.withOpacity(.5))),
      onTap: onTap,
    ));

  Widget _art(String url, {double size = 54}) => ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: Container(width: size, height: size, color: const Color(0xFF252B35),
      child: url.isEmpty ? const Icon(Icons.music_note, color: accent) :
      Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) =>
        const Icon(Icons.music_note, color: accent))),
  );

  Widget _miniPlayer() => StreamBuilder<PlaybackState>(
    stream: audioHandler.playbackState,
    builder: (context, snapshot) {
      final state = snapshot.data;
      if (current == null || state == null) return const SizedBox.shrink();
      return InkWell(
        onTap: _showPlayer,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: const Color(0xFF202631),
          child: Row(children: [
            _art(current!.artwork, size: 42),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(current!.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(current!.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(.55), fontSize: 12)),
            ])),
            IconButton(icon: Icon(state.playing ? Icons.pause : Icons.play_arrow, color: accent),
              onPressed: () => state.playing ? audioHandler.pause() : audioHandler.play()),
            IconButton(icon: const Icon(Icons.open_in_full), onPressed: _showPlayer),
          ]),
        ),
      );
    },
  );
}

class PlayerSheet extends StatelessWidget {
  final Song song;
  const PlayerSheet({super.key, required this.song});

  String _time(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 30),
      child: StreamBuilder<PlaybackState>(
        stream: audioHandler.playbackState,
        builder: (context, snap) {
          final state = snap.data;
          return StreamBuilder<Duration?>(
            stream: audioHandler is StamenAudioHandler
                ? (audioHandler as StamenAudioHandler).positionStream
                : const Stream.empty(),
            builder: (context, posSnap) {
              final position = posSnap.data ?? Duration.zero;
              final duration = Duration(seconds: song.duration);
              final max = duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 42, height: 4, decoration: BoxDecoration(
                  color: Colors.white24, borderRadius: BorderRadius.circular(4))),
                const SizedBox(height: 24),
                ClipRRect(borderRadius: BorderRadius.circular(20),
                  child: Container(width: 270, height: 270, color: panel,
                    child: song.artwork.isEmpty ? const Icon(Icons.music_note, size: 90, color: accent) :
                    Image.network(song.artwork, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 90, color: accent)))),
                const SizedBox(height: 28),
                Text(song.title, textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Text(song.artist, style: TextStyle(color: Colors.white.withOpacity(.6), fontSize: 15)),
                const SizedBox(height: 24),
                Slider(
                  value: position.inMilliseconds.clamp(0, max.toInt()).toDouble(),
                  max: max, activeColor: accent, inactiveColor: Colors.white24,
                  onChanged: (v) => audioHandler.seek(Duration(milliseconds: v.round())),
                ),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(_time(position), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  Text(_time(duration), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ]),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(iconSize: 34, onPressed: null, icon: const Icon(Icons.shuffle, color: Colors.white38)),
                  IconButton(iconSize: 42, onPressed: null, icon: const Icon(Icons.skip_previous, color: Colors.white38)),
                  const SizedBox(width: 12),
                  Container(
                    decoration: const BoxDecoration(color: accent, shape: BoxShape.circle),
                    child: IconButton(iconSize: 36, color: Colors.black,
                      icon: Icon(state?.playing == true ? Icons.pause : Icons.play_arrow),
                      onPressed: () => state?.playing == true ? audioHandler.pause() : audioHandler.play()),
                  ),
                  const SizedBox(width: 12),
                  IconButton(iconSize: 42, onPressed: null, icon: const Icon(Icons.skip_next, color: Colors.white38)),
                  IconButton(iconSize: 30, onPressed: null, icon: const Icon(Icons.repeat, color: Colors.white38)),
                ]),
                const SizedBox(height: 8),
                Text('Streaming • Stamen', style: TextStyle(color: Colors.white.withOpacity(.4), fontSize: 12)),
              ]);
            },
          );
        },
      ),
    ),
  );
}

