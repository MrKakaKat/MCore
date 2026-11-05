/// The app's language: English text as the key, the Russian beside it.
/// A string with no translation shows in English.
library;

/// 'en' or 'ru' (set from AppSettings at start and by the home settings).
String appLanguage = 'en';

/// `en` in the app's language.
String tr(String en) => appLanguage == 'ru' ? (_ru[en] ?? en) : en;

const _ru = <String, String>{
  // home
  'Projects': 'Проекты',
  'New project': 'Новый проект',
  'No projects yet - tap "New project" to start.': 'Проектов пока нет - нажмите «Новый проект».',
  'Play full screen': 'Воспроизвести',
  'Rename': 'Переименовать',
  'Duplicate': 'Дублировать',
  'Used in...': 'Где используется...',
  'Delete': 'Удалить',
  'Prompt for AI...': 'Промпт для ИИ...',
  'Import from text...': 'Импорт из текста...',
  'Back up everything...': 'Резервная копия...',
  'Restore a backup...': 'Восстановить копию...',
  'Add performance test projects': 'Добавить тестовые проекты',
  'Settings': 'Настройки',
  'Sort projects by': 'Сортировать проекты',
  'Date modified': 'По дате изменения',
  'Date created': 'По дате создания',
  'Language': 'Язык',
  'Close': 'Закрыть',
  'Cancel': 'Отмена',
  // editor tabs
  'Layers': 'Слои',
  'Movement': 'Движение',
  'Keyframes': 'Ключи',
  'Timeline': 'Таймлайн',
  'Masks': 'Маски',
  'Effects': 'Эффекты',
  'Collide': 'Столкновения',
  'Figures': 'Фигуры',
  'Filters': 'Фильтры',
  'Links': 'Связи',
  'Palettes': 'Палитры',
  'Text': 'Текст',
  'Line': 'Линия',
  'Crop': 'Обрезка',
  'Chroma': 'Хромакей',
  'Audio': 'Звук',
  'Reverse': 'Реверс',
  'Presets': 'Пресеты',
  'Stage': 'Сцена',
  'Snapping': 'Привязка',
  'Contour': 'Контур',
};
