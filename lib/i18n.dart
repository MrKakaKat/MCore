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
  'MCore closed unexpectedly': 'MCore закрылся неожиданно',
  'Copy report': 'Скопировать отчёт',
  'Copied - send it to fix the crash': 'Скопировано - пришлите, чтобы исправить вылет',
  'No projects yet - tap "New project" to start.': 'Проектов пока нет - нажмите «Новый проект».',
  'Play full screen': 'Воспроизвести',
  'Rename': 'Переименовать',
  'Duplicate': 'Дублировать',
  'Used in...': 'Где используется...',
  'Delete': 'Удалить',
  'Trash': 'Корзина',
  'Empty trash': 'Очистить',
  'Restore': 'Восстановить',
  'Delete for good': 'Удалить навсегда',
  'Prompt for AI...': 'Промпт для ИИ...',
  'Import from text...': 'Импорт из текста...',
  'Back up everything...': 'Резервная копия...',
  'Restore a backup...': 'Восстановить копию...',
  'Projects outside the app...': 'Проекты вне приложения...',
  'Projects outside the app': 'Проекты вне приложения',
  'Pick a folder: every project with its media is kept there too (one file, MCore-projects.zip, written over after each change). It outlives the app - restore it with "Restore a backup".':
      'Выберите папку: все проекты с медиа будут храниться и там (один файл MCore-projects.zip, перезаписывается после каждого изменения). Он переживёт приложение - вернуть его можно через «Восстановить копию».',
  'Kept in': 'Хранятся в',
  'Stop': 'Отключить',
  'Save now': 'Сохранить сейчас',
  'Pick a folder': 'Выбрать папку',
  'Another folder': 'Другая папка',
  'Keep projects in': 'Хранить проекты в',
  'Saving the projects there...': 'Сохраняю проекты туда...',
  'Projects kept in': 'Проекты сохранены в',
  'Could not keep the projects in the folder': 'Не удалось сохранить проекты в папку',
  'Cache...': 'Кеш...',
  'Cache': 'Кеш',
  'video frames, decoded sound and scratch files; all of it is made again when needed (a video takes a moment the first time).':
      'кадры видео, расшифрованный звук и временные файлы; всё это создаётся заново, когда нужно (видео в первый раз подготовится не сразу).',
  'Clear': 'Очистить',
  'Cache cleared': 'Кеш очищен',
  'The app did not start last time: this time the cache was made afresh and your own fonts were left out. Back up your projects now to be safe.':
      'В прошлый раз приложение не запустилось: сейчас кеш создан заново, а ваши шрифты не загружены. На всякий случай сохраните проекты.',
  'Keep them outside': 'Сохранить вне приложения',
  'OK': 'OK',
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
  'Objects': 'Объекты',
  'Drawing': 'Рисование',
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
