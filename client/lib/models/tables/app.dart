class App {
  String id;
  String name;
  String slug;
  String group;
  int order;
  int? icon;
  String route;

  App({
    required this.id,
    required this.name,
    required this.slug,
    required this.group,
    required this.order,
    this.icon,
    required this.route,
  });

  factory App.fromDbMap(Map<String, dynamic> map) {
    return App(
      id: map['id'] as String,
      name: map['name'] as String,
      slug: map['slug'] as String,
      group: map['group'] as String? ?? 'collections',
      order: map['order'] as int? ?? 0,
      icon: map['icon'] as int?,
      route: map['route'] as String? ?? '/',
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'id': id,
      'name': name,
      'slug': slug,
      'group': group,
      'order': order,
      'icon': icon,
      'route': route,
    };
  }
}
