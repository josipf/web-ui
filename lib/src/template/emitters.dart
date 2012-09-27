// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/** Collects several code emitters for the template tool. */
// TODO(sigmund): add visitor that applies all emitters on a component
// TODO(sigmund): add support for conditionals, so context is changed at that
// point.
library emitters;

import 'package:html5lib/dom.dart';

import 'code_printer.dart';
import 'codegen.dart' as codegen;
import 'info.dart';
import 'source_file.dart';

/**
 * An emitter for a web component feature.  It collects all the logic for
 * emitting a particular feature (such as data-binding, event hookup) with
 * respect to a single HTML element.
 */
abstract class Emitter<T extends ElementInfo> {
  /** Element for which code is being emitted. */
  Element elem;

  /** Information about the element for which code is being emitted. */
  T elemInfo;

  Emitter(this.elem, this.elemInfo);

  /** Emit declarations needed by this emitter's feature. */
  void emitDeclarations(Context context) {}

  /** Emit feature-related statemetns in the `created` method. */
  void emitCreated(Context context) {}

  /** Emit feature-related statemetns in the `inserted` method. */
  void emitInserted(Context context) {}

  /** Emit feature-related statemetns in the `removed` method. */
  void emitRemoved(Context context) {}

  // The following are helper methods to make it simpler to write emitters.
  Context contextForChildren(Context context) => context;

  /** Generates a unique Dart identifier in the given [context]. */
  String newName(Context context, String prefix) =>
      '${prefix}${context.nextId()}';
}

/**
 * Context used by an emitter. Typically representing where to generate code
 * and additional information, such as total number of generated identifiers.
 */
class Context {
  final CodePrinter declarations;
  final CodePrinter createdMethod;
  final CodePrinter insertedMethod;
  final CodePrinter removedMethod;
  final String queryFromElement;

  Context([CodePrinter declarations,
           CodePrinter createdMethod,
           CodePrinter insertedMethod,
           CodePrinter removedMethod,
           this.queryFromElement])
      : this.declarations = getOrCreatePrinter(declarations),
        this.createdMethod = getOrCreatePrinter(createdMethod),
        this.insertedMethod = getOrCreatePrinter(insertedMethod),
        this.removedMethod = getOrCreatePrinter(removedMethod);

  // TODO(sigmund): keep separate counters for ids, listeners, watchers?
  int _totalIds = 0;
  int nextId() => ++_totalIds;

  static getOrCreatePrinter(CodePrinter p) => p != null ? p : new CodePrinter();
}

/**
 * Generates a field for any element that has either event listeners or data
 * bindings.
 */
class ElementFieldEmitter extends Emitter<ElementInfo> {
  ElementFieldEmitter(Element elem, ElementInfo info) : super(elem, info);

  void emitDeclarations(Context context) {
    if (elemInfo.elemField != null) {
      context.declarations.add('Element ${elemInfo.elemField};');
    }
  }

  void emitCreated(Context context) {
    if (elemInfo.elemField == null) return;

    var queryFrom = context.queryFromElement;
    var field = elemInfo.elemField;
    var id = elemInfo.elementId;
    if (queryFrom != null) {
      // TODO(jmesserly): we should be able to figure out if IDs match
      // statically.
      // Note: This code is more complex because it must handle the case
      // where the queryFrom node itself has the ID.
      context.createdMethod.add('''
        if ($queryFrom.id == "$id") {
          $field = $queryFrom;
        } else {
          $field = $queryFrom.query('#$id');
        }''');
    } else {
      context.createdMethod.add("$field = root.query('#$id');");
    }
  }
}

/**
 * Generates event listeners attached to a node and code that attaches/detaches
 * the listener.
 */
class EventListenerEmitter extends Emitter<ElementInfo> {

  EventListenerEmitter(Element elem, ElementInfo info)
      : super(elem, info);

  /** Generate a field for each listener, so it can be detached on `removed`. */
  void emitDeclarations(Context context) {
    elemInfo.events.forEach((name, eventInfo) {
      eventInfo.listenerField = newName(context, '_listener_${name}_');
      context.declarations.add('EventListener ${eventInfo.listenerField};');
    });
  }

  /** Define the listeners. */
  // TODO(sigmund): should the definition of listener be done in `created`?
  void emitInserted(Context context) {
    var elemField = elemInfo.elemField;
    elemInfo.events.forEach((name, eventInfo) {
      var field = eventInfo.listenerField;
      context.insertedMethod.add('''
          $field = (_) {
            ${eventInfo.action(elemField)};
            dispatch();
          };
          $elemField.on.${eventInfo.eventName}.add($field);
      ''');
    });
  }

  /** Emit feature-related statemetns in the `removed` method. */
  void emitRemoved(Context context) {
    var elemField = elemInfo.elemField;
    elemInfo.events.forEach((name, eventInfo) {
      var field = eventInfo.listenerField;
      context.removedMethod.add('''
          $elemField.on.${eventInfo.eventName}.remove($field);
          $field = null;
      ''');
    });
  }
}

/** Generates watchers that listen on data changes and update a DOM element. */
class DataBindingEmitter extends Emitter<ElementInfo> {
  DataBindingEmitter(Element elem, ElementInfo info)
      : super(elem, info);

  /** Emit a field for each disposer function. */
  void emitDeclarations(Context context) {
    var elemField = elemInfo.elemField;
    elemInfo.attributes.forEach((name, attrInfo) {
      attrInfo.stopperNames = [];
      attrInfo.bindings.forEach((b) {
        var stopperName = newName(context, '_stopWatcher${elemField}_');
        attrInfo.stopperNames.add(stopperName);
        context.declarations.add('WatcherDisposer $stopperName;');
      });
    });

    if (elemInfo.contentBinding != null) {
      elemInfo.stopperName = newName(context, '_stopWatcher${elemField}_');
      context.declarations.add('WatcherDisposer ${elemInfo.stopperName};');
    }
  }

  /** Watchers for each data binding. */
  void emitInserted(Context context) {
    var elemField = elemInfo.elemField;
    // stop-functions for watchers associated with data-bound attributes
    elemInfo.attributes.forEach((name, attrInfo) {
      if (attrInfo.isClass) {
        for (int i = 0; i < attrInfo.bindings.length; i++) {
          var stopperName = attrInfo.stopperNames[i];
          var exp = attrInfo.bindings[i];
          context.insertedMethod.add('''
              $stopperName = watchAndInvoke(() => $exp, (e) {
                if (e.oldValue != null && e.oldValue != '') {
                  $elemField.classes.remove(e.oldValue);
                }
                if (e.newValue != null && e.newValue != '') {
                  $elemField.classes.add(e.newValue);
                }
              });
          ''');
        }
      } else {
        var val = attrInfo.boundValue;
        var stopperName = attrInfo.stopperNames[0];
        context.insertedMethod.add('''
            $stopperName = watchAndInvoke(() => $val, (e) {
              $elemField.$name = e.newValue;
            });
        ''');
      }
    });

    // stop-functions for watchers associated with data-bound content
    if (elemInfo.contentBinding != null) {
      var stopperName = elemInfo.stopperName;
      // TODO(sigmund): track all subexpressions, not just the first one.
      var val = elemInfo.contentBinding;
      context.insertedMethod.add('''
          $stopperName = watchAndInvoke(() => $val, (e) {
            $elemField.innerHTML = ${elemInfo.contentExpression};
          });
      ''');
    }
  }

  /** Call the dispose method on all watchers. */
  void emitRemoved(Context context) {
    elemInfo.attributes.forEach((name, attrInfo) {
      attrInfo.stopperNames.forEach((stopperName) {
        context.removedMethod.add('$stopperName();');
      });
    });
    if (elemInfo.contentBinding != null) {
      context.removedMethod.add('${elemInfo.stopperName}();');
    }
  }
}

/**
 * Emits code for web component instantiation. For example, if the source has:
 *
 *     <x-hello>John</x-hello>
 *
 * And the component has been defined as:
 *
 *    <element name="x-hello" extends="div" constructor="HelloComponent">
 *      <template>Hello, <content>!</template>
 *      <script type="application/dart"></script>
 *    </element>
 *
 * This will ensure that the Dart HelloComponent for `x-hello` is created and
 * attached to the appropriate DOM node.
 *
 * Also, this copies values from the scope into the object at component creation
 * time, for example:
 *
 *     <x-foo data-value="bar:baz">
 *
 * This will set the "bar" property of FooComponent to be "baz".
 */
class ComponentInstanceEmitter extends Emitter<ElementInfo> {
  ComponentInstanceEmitter(Element elem, ElementInfo info) : super(elem, info);

  void emitCreated(Context context) {
    var component = elemInfo.component;
    if (component == null) return;

    var id = elemInfo.idAsIdentifier;
    context.createdMethod.add(
        'var component$id = new ${component.constructor}.forElement($id);');

    elemInfo.values.forEach((name, value) {
      context.createdMethod.add('component$id.$name = $value;');
    });

    context.createdMethod.add('component$id.createShadowRoot();');
  }

  void emitInserted(Context context) {
    if (elemInfo.component == null) return;

    var id = elemInfo.idAsIdentifier;
    context.insertedMethod.add('($id as Dynamic).xtag.inserted();');
  }

  void emitRemoved(Context context) {
    if (elemInfo.component == null) return;

    var id = elemInfo.idAsIdentifier;
    context.removedMethod.add('($id as Dynamic).xtag.removed();');
  }
}


/** Emitter of template conditionals like `<template instantiate='if test'>`. */
class ConditionalEmitter extends Emitter<TemplateInfo> {
  final CodePrinter childrenCreated;
  final CodePrinter childrenRemoved;
  final CodePrinter childrenInserted;

  ConditionalEmitter(Element elem, ElementInfo info)
      : childrenCreated = new CodePrinter(),
        childrenRemoved = new CodePrinter(),
        childrenInserted = new CodePrinter(),
        super(elem, info);

  void emitDeclarations(Context context) {
    var id = elemInfo.idAsIdentifier;
    context.declarations.add('''
        // Fields for template conditional '${elemInfo.elementId}'
        WatcherDisposer _stopWatcher_if$id;
        Element _childTemplate$id;
        Element _parent$id;
        Element _child$id;
        String _childId$id;
    ''');
  }

  void emitCreated(Context context) {
    var id = elemInfo.idAsIdentifier;
    context.createdMethod.add('''
        assert($id.elements.length == 1);
        _childTemplate$id = $id.elements[0];
        _childId$id = _childTemplate$id.id;
        if (_childId$id != null && _childId$id != '') {
          _childTemplate$id.id = '';
        }
        $id.style.display = 'none';
        $id.nodes.clear();
    ''');
  }

  void emitInserted(Context context) {
    var id = elemInfo.idAsIdentifier;
    var condition = (elemInfo as TemplateInfo).ifCondition;
    context.insertedMethod.add('''
        _stopWatcher_if$id = watchAndInvoke(() => $condition, (e) {
          bool showNow = e.newValue;
          if (_child$id != null && !showNow) {
            // Remove any listeners/watchers on children
    ''');
    context.insertedMethod.add(childrenRemoved);

    context.insertedMethod.add('''
            // Remove the actual child
            _child$id.remove();
            _child$id = null;
          } else if (_child$id == null && showNow) {
            _child$id = _childTemplate$id.clone(true);
            if (_childId$id != null && _childId$id != '') {
              _child$id.id = _childId$id;
            }
            // Initialize children
    ''');
    context.insertedMethod.add(childrenCreated);
    context.insertedMethod.add('$id.parent.nodes.add(_child$id);');
    context.insertedMethod.add('// Attach listeners/watchers');
    context.insertedMethod.add(childrenInserted);
    context.insertedMethod.add('''

          }
        });
    ''');
  }

  void emitRemoved(Context context) {
    var id = elemInfo.idAsIdentifier;
    context.removedMethod.add('''
        _stopWatcher_if$id();
        if (_child$id != null) {
          _child$id.remove();
          // Remove any listeners/watchers on children
    ''');
    context.removedMethod.add(childrenRemoved);
    context.removedMethod.add('}');
  }

  Context contextForChildren(Context c) => new Context(
      c.declarations, childrenCreated, childrenInserted, childrenRemoved,
      '_child${elemInfo.idAsIdentifier}');
}


/**
 * Emitter of template lists like `<template iterate='item in items'>`.
 */
class ListEmitter extends Emitter<TemplateInfo> {
  // TODO(jmesserly): can these be final?
  final CodePrinter childrenDeclarations;
  final CodePrinter childrenCreated;
  final CodePrinter childrenRemoved;
  final CodePrinter childrenInserted;

  ListEmitter(Element elem, TemplateInfo info)
      : childrenDeclarations = new CodePrinter(),
        childrenCreated = new CodePrinter(),
        childrenRemoved = new CodePrinter(),
        childrenInserted = new CodePrinter(),
        super(elem, info);

  String get childElementName => 'child${elemInfo.idAsIdentifier}';

  void emitDeclarations(Context context) {
    var id = elemInfo.idAsIdentifier;
    context.declarations.add('''
        // Fields for template list '${elemInfo.elementId}'
        Element _childTemplate$id;
        WatcherDisposer _stopWatcher$id;
        List<WatcherDisposer> _removeChild$id;
    ''');
  }

  void emitCreated(Context context) {
    var id = elemInfo.idAsIdentifier;
    context.createdMethod.add('''
        assert($id.elements.length == 1);
        _childTemplate$id = $id.elements[0];
        _removeChild$id = [];
        $id.nodes.clear();
    ''');
  }

  void emitInserted(Context context) {
    var id = elemInfo.idAsIdentifier;
    // TODO(jmesserly): this should use fine grained updates.
    // TODO(jmesserly): watcher should give us the list, not a boolean.
    context.insertedMethod.add('''
        _stopWatcher$id = watchAndInvoke(() => ${elemInfo.loopItems}, (e) {
          for (var remover in _removeChild$id) remover();
          _removeChild$id.clear();
          for (var ${elemInfo.loopVariable} in ${elemInfo.loopItems}) {
            var $childElementName = _childTemplate$id.clone(true);
    ''');

    context.insertedMethod
        .add(childrenDeclarations)
        .add(childrenCreated)
        .add('$id.parent.nodes.add($childElementName);')
        .add('// Attach listeners/watchers')
        .add(childrenInserted)
        .add('// Remember to unregister them')
        .add('_removeChild$id.add(() {')
        .add('$childElementName.remove();')
        .add(childrenRemoved)
        .add('});\n}\n});');
  }

  void emitRemoved(Context context) {
    var id = elemInfo.idAsIdentifier;
    context.removedMethod.add('''
        _stopWatcher$id();
        for (var remover in _removeChild$id) remover();
        _removeChild$id.clear();
    ''');
  }

  Context contextForChildren(Context c) => new Context(
      childrenDeclarations, childrenCreated, childrenInserted, childrenRemoved,
      queryFromElement: childElementName);
}


/**
 * An visitor that applies [ElementFieldEmitter], [EventListenerEmitter],
 * [DataBindingEmitter], [DataValueEmitter], [ConditionalEmitter], and
 * [ListEmitter] recursively on a DOM tree.
 */
class RecursiveEmitter extends TreeVisitor {
  final FileInfo _info;
  Context _context;

  RecursiveEmitter(this._info) : _context = new Context();

  void visitElement(Element elem) {
    var elemInfo = _info.elements[elem];
    if (elemInfo == null) {
      super.visitElement(elem);
      return;
    }

    var emitters = [new ElementFieldEmitter(elem, elemInfo),
        new EventListenerEmitter(elem, elemInfo),
        new DataBindingEmitter(elem, elemInfo),
        new ComponentInstanceEmitter(elem, elemInfo)];

    var childContext = _context;
    if (elemInfo.hasIfCondition) {
      var condEmitter = new ConditionalEmitter(elem, elemInfo);
      emitters.add(condEmitter);
      childContext = condEmitter.contextForChildren(_context);
    } else if (elemInfo.hasIterate) {
      var listEmitter = new ListEmitter(elem, elemInfo);
      emitters.add(listEmitter);
      childContext = listEmitter.contextForChildren(_context);
    }

    emitters.forEach((e) {
      e.emitDeclarations(_context);
      e.emitCreated(_context);
      e.emitInserted(_context);
      e.emitRemoved(_context);
    });

    var oldContext = _context;
    _context = childContext;

    // Invoke super to visit children.
    super.visitElement(elem);

    _context = oldContext;
  }
}

/** Generates the class corresponding to a single web component. */
class WebComponentEmitter extends RecursiveEmitter {
  WebComponentEmitter(FileInfo info) : super(info);

  String run(ComponentInfo info) {
    if (info.element.attributes['apply-author-styles'] != null) {
      _context.createdMethod.add(
          'if (root is ShadowRoot) root.applyAuthorStyles = true;');
    }
    if (info.template != null) {
      // TODO(jmesserly): we don't need to emit the HTML file for components
      // anymore, because we're handling it here.

      // TODO(jmesserly): we need to emit code to run the <content> distribution
      // algorithm for browsers without ShadowRoot support.

      // TODO(jmesserly): is raw triple quote enough to escape the HTML?
      // We have a similar issue in mainDartCode.
      _context.createdMethod.add("""
        root.innerHTML = r'''
          ${info.template.innerHTML.trim()}
        ''';
      """);
    }

    visit(info.element);

    return codegen.componentCode(info,
        _context.declarations.formatString(1),
        _context.createdMethod.formatString(2),
        _context.insertedMethod.formatString(2),
        _context.removedMethod.formatString(2));
  }
}

/** Emits the Dart code for all components in the [file]. */
String emitComponents(FileInfo file) {
  var result = new StringBuffer();
  result.add(codegen.header(file));
  for (var component in file.declaredComponents) {
    result.add(new WebComponentEmitter(file).run(component));
  }
  return result.toString();
}

/** Generates the class corresponding to the main html page. */
class MainPageEmitter extends RecursiveEmitter {
  MainPageEmitter(FileInfo info) : super(info);

  String run(Document document) {
    visit(document);

    return codegen.mainDartCode(
        emitComponents(_info),
        _context.declarations.formatString(0),
        _context.createdMethod.formatString(1),
        _context.insertedMethod.formatString(1),
        document.body.innerHTML.trim());
  }
}