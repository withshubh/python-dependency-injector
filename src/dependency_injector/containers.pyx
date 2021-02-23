"""Containers module."""

import sys

try:
    import asyncio
except ImportError:
    asyncio = None

import six

from . import providers, errors
from .providers cimport __is_future_or_coroutine


if sys.version_info[:2] >= (3, 6):
    from .wiring import wire, unwire
else:
    def wire(*args, **kwargs):
        raise NotImplementedError('Wiring requires Python 3.6 or above')

    def unwire(*args, **kwargs):
        raise NotImplementedError('Wiring requires Python 3.6 or above')


class Container(object):
    """Abstract container."""


class DynamicContainer(Container):
    """Dynamic inversion of control container.

    .. code-block:: python

        services = DynamicContainer()
        services.auth = providers.Factory(AuthService)
        services.users = providers.Factory(UsersService,
                                           auth_service=services.auth)

    .. py:attribute:: providers

        Read-only dictionary of all providers.

        :type: dict[str, :py:class:`dependency_injector.providers.Provider`]

    .. py:attribute:: overridden

        Tuple of overriding containers.

        :type: tuple[:py:class:`DynamicContainer`]

    .. py:attribute:: provider_type

        Type of providers that could be placed in container.

        :type: type
    """

    __IS_CONTAINER__ = True

    def __init__(self):
        """Initializer.

        :rtype: None
        """
        self.provider_type = providers.Provider
        self.providers = {}
        self.overridden = tuple()
        self.parent = None
        self.declarative_parent = None
        self.wired_to_modules = []
        self.wired_to_packages = []
        self.__self__ = providers.Self(self)
        super(DynamicContainer, self).__init__()

    def __deepcopy__(self, memo):
        """Create and return full copy of container."""
        copied = memo.get(id(self))
        if copied is not None:
            return copied

        copied = self.__class__()
        memo[id(self)] = copied

        copied.provider_type = providers.Provider
        copied.overridden = providers.deepcopy(self.overridden, memo)
        copied.declarative_parent = self.declarative_parent

        copied.__self__ = providers.deepcopy(self.__self__, memo)
        for name in copied.__self__.alt_names:
            copied.set_provider(name, copied.__self__)

        for name, provider in providers.deepcopy(self.providers, memo).items():
            copied.set_provider(name, provider)

        copied.parent = providers.deepcopy(self.parent, memo)

        return copied

    def __setattr__(self, str name, object value):
        """Set instance attribute.

        If value of attribute is provider, it will be added into providers
        dictionary.

        :param name: Attribute's name
        :type name: str

        :param value: Attribute's value
        :type value: object

        :rtype: None
        """
        if isinstance(value, providers.Provider) \
                and not isinstance(value, providers.Self) \
                and name != 'parent':
            _check_provider_type(self, value)

            self.providers[name] = value

            if isinstance(value, providers.CHILD_PROVIDERS):
                value.assign_parent(self)

        super(DynamicContainer, self).__setattr__(name, value)

    def __delattr__(self, str name):
        """Delete instance attribute.

        If value of attribute is provider, it will be deleted from providers
        dictionary.

        :param name: Attribute's name
        :type name: str

        :rtype: None
        """
        if name in self.providers:
            del self.providers[name]
        super(DynamicContainer, self).__delattr__(name)

    @property
    def dependencies(self):
        """Return dependency providers dictionary.

        Dependency providers can be both of :py:class:`dependency_injector.providers.Dependency` and
        :py:class:`dependency_injector.providers.DependenciesContainer`.

        :rtype:
            dict[str, :py:class:`dependency_injector.providers.Provider`]
        """
        return {
            name: provider
            for name, provider in self.providers.items()
            if isinstance(provider, (providers.Dependency, providers.DependenciesContainer))
        }

    def traverse(self, types=None):
        """Return providers traversal generator."""
        yield from providers.traverse(*self.providers.values(), types=types)

    def set_providers(self, **providers):
        """Set container providers.

        :param providers: Dictionary of providers
        :type providers:
            dict[str, :py:class:`dependency_injector.providers.Provider`]

        :rtype: None
        """
        for name, provider in six.iteritems(providers):
            setattr(self, name, provider)

    def set_provider(self, name, provider):
        """Set container provider.

        :param name: Provider name
        :type name: str

        :param provider: Provider
        :type provider: :py:class:`dependency_injector.providers.Provider`

        :rtype: None
        """
        setattr(self, name, provider)

    def override(self, object overriding):
        """Override current container by overriding container.

        :param overriding: Overriding container.
        :type overriding: :py:class:`DynamicContainer`

        :raise: :py:exc:`dependency_injector.errors.Error` if trying to
                override container by itself

        :rtype: None
        """
        if overriding is self:
            raise errors.Error('Container {0} could not be overridden '
                               'with itself'.format(self))

        self.overridden += (overriding,)

        for name, provider in six.iteritems(overriding.providers):
            try:
                getattr(self, name).override(provider)
            except AttributeError:
                pass

    def override_providers(self, **overriding_providers):
        """Override container providers.

        :param overriding_providers: Dictionary of providers
        :type overriding_providers:
            dict[str, :py:class:`dependency_injector.providers.Provider`]

        :rtype: None
        """
        for name, overriding_provider in six.iteritems(overriding_providers):
            container_provider = getattr(self, name)
            container_provider.override(overriding_provider)

    def reset_last_overriding(self):
        """Reset last overriding provider for each container providers.

        :rtype: None
        """
        if not self.overridden:
            raise errors.Error('Container {0} is not overridden'.format(self))

        self.overridden = self.overridden[:-1]

        for provider in six.itervalues(self.providers):
            provider.reset_last_overriding()

    def reset_override(self):
        """Reset all overridings for each container providers.

        :rtype: None
        """
        self.overridden = tuple()

        for provider in six.itervalues(self.providers):
            provider.reset_override()

    def wire(self, modules=None, packages=None):
        """Wire container providers with provided packages and modules.

        :rtype: None
        """
        wire(
            container=self,
            modules=modules,
            packages=packages,
        )

        if modules:
            self.wired_to_modules.extend(modules)

        if packages:
            self.wired_to_packages.extend(packages)

    def unwire(self):
        """Unwire container providers from previously wired packages and modules."""
        unwire(
            modules=self.wired_to_modules,
            packages=self.wired_to_packages,
        )

        self.wired_to_modules.clear()
        self.wired_to_packages.clear()

    def init_resources(self):
        """Initialize all container resources."""
        futures = []

        for provider in self.traverse(types=[providers.Resource]):
            resource = provider.init()

            if __is_future_or_coroutine(resource):
                futures.append(resource)

        if futures:
            return asyncio.gather(*futures)

    def shutdown_resources(self):
        """Shutdown all container resources."""
        futures = []

        for provider in self.traverse(types=[providers.Resource]):
            shutdown = provider.shutdown()

            if __is_future_or_coroutine(shutdown):
                futures.append(shutdown)

        if futures:
            return asyncio.gather(*futures)

    def apply_container_providers_overridings(self):
        """Apply container providers' overridings."""
        for provider in self.traverse(types=[providers.Container]):
            provider.apply_overridings()

    def reset_singletons(self):
        """Reset container singletons."""
        for provider in self.traverse(types=[providers.BaseSingleton]):
            provider.reset()

    def check_dependencies(self):
        """Check if container dependencies are defined.

        If any dependency is undefined, raises an error.
        """
        undefined = [
            dependency
            for dependency in self.traverse(types=[providers.Dependency])
            if not dependency.is_defined
        ]

        if not undefined:
            return

        container_name = self.parent_name if self.parent_name else self.__class__.__name__
        undefined_names = [
            f'"{dependency.parent_name if dependency.parent_name else dependency}"'
            for dependency in undefined
        ]
        raise errors.Error(
            f'Container "{container_name}" has undefined dependencies: '
            f'{", ".join(undefined_names)}',
        )

    def from_schema(self, schema):
        """Build container providers from schema."""
        from .schema import build_schema
        for name, provider in build_schema(schema).items():
            self.set_provider(name, provider)

    def from_yaml_schema(self, filepath):
        """Build container providers from YAML file schema."""
        # TODO
        ...

    def from_json_schema(self, filepath):
        """Build container providers from JSON file schema."""
        # TODO
        ...

    def resolve_provider_name(self, provider):
        """Try to resolve provider name."""
        for provider_name, container_provider in self.providers.items():
            if container_provider is provider:
                return provider_name
        else:
            raise errors.Error(f'Can not resolve name for provider "{provider}"')

    @property
    def parent_name(self):
        """Return parent name."""
        if self.parent:
            return self.parent.parent_name

        if self.declarative_parent:
            return self.declarative_parent.__name__

        return None

    def assign_parent(self, parent):
        """Assign parent."""
        self.parent = parent


class DeclarativeContainerMetaClass(type):
    """Declarative inversion of control container meta class."""

    def __new__(type mcs, str class_name, tuple bases, dict attributes):
        """Declarative container class factory."""
        self = mcs.__fetch_self(attributes)
        if self is None:
            self = providers.Self()

        containers = {
            name: container
            for name, container in six.iteritems(attributes)
            if is_container(container)
        }

        cls_providers = {
            name: provider
            for name, provider in six.iteritems(attributes)
            if isinstance(provider, providers.Provider) and not isinstance(provider, providers.Self)
        }

        inherited_providers = {
            name: provider
            for base in bases
            if is_container(base) and base is not DynamicContainer
            for name, provider in six.iteritems(base.providers)
        }

        all_providers = {}
        all_providers.update(inherited_providers)
        all_providers.update(cls_providers)

        attributes['containers'] = containers
        attributes['inherited_providers'] = inherited_providers
        attributes['cls_providers'] = cls_providers
        attributes['providers'] = all_providers

        cls = <type>type.__new__(mcs, class_name, bases, attributes)

        self.set_container(cls)
        cls.__self__ = self

        for provider in six.itervalues(cls.providers):
            _check_provider_type(cls, provider)

        for provider in six.itervalues(cls.cls_providers):
            if isinstance(provider, providers.CHILD_PROVIDERS):
                provider.assign_parent(cls)

        return cls

    def __setattr__(cls, str name, object value):
        """Set class attribute.

        If value of attribute is provider, it will be added into providers
        dictionary.

        :param name: Attribute's name
        :type name: str

        :param value: Attribute's value
        :type value: object

        :rtype: None
        """
        if isinstance(value, providers.Provider) and name != '__self__':
            _check_provider_type(cls, value)

            if isinstance(value, providers.CHILD_PROVIDERS):
                value.assign_parent(cls)

            cls.providers[name] = value
            cls.cls_providers[name] = value
        super(DeclarativeContainerMetaClass, cls).__setattr__(name, value)

    def __delattr__(cls, str name):
        """Delete class attribute.

        If value of attribute is provider, it will be deleted from providers
        dictionary.

        :param name: Attribute's name
        :type name: str

        :rtype: None
        """
        if name in cls.providers and name in cls.cls_providers:
            del cls.providers[name]
            del cls.cls_providers[name]
        super(DeclarativeContainerMetaClass, cls).__delattr__(name)

    @property
    def dependencies(cls):
        """Return dependency providers dictionary.

        Dependency providers can be both of :py:class:`dependency_injector.providers.Dependency` and
        :py:class:`dependency_injector.providers.DependenciesContainer`.

        :rtype:
            dict[str, :py:class:`dependency_injector.providers.Provider`]
        """
        return {
            name: provider
            for name, provider in cls.providers.items()
            if isinstance(provider, (providers.Dependency, providers.DependenciesContainer))
        }

    def traverse(cls, types=None):
        """Return providers traversal generator."""
        yield from providers.traverse(*cls.providers.values(), types=types)

    def resolve_provider_name(cls, provider):
        """Try to resolve provider name."""
        for provider_name, container_provider in cls.providers.items():
            if container_provider is provider:
                return provider_name
        else:
            raise errors.Error(f'Can not resolve name for provider "{provider}"')

    @property
    def parent_name(cls):
        """Return parent name."""
        return cls.__name__

    @staticmethod
    def __fetch_self(attributes):
        self = None
        alt_names = []

        for name, value in attributes.items():
            if not isinstance(value, providers.Self):
                continue

            if self is not None and value is not self:
                raise errors.Error('Container can have only one "Self" provider')

            if name != '__self__':
                alt_names.append(name)

            self = value

        if self:
            self.set_alt_names(alt_names)

        return self


@six.add_metaclass(DeclarativeContainerMetaClass)
class DeclarativeContainer(Container):
    """Declarative inversion of control container.

    .. code-block:: python

        class Services(DeclarativeContainer):
            auth = providers.Factory(AuthService)
            users = providers.Factory(UsersService,
                                      auth_service=auth)
    """

    __IS_CONTAINER__ = True

    provider_type = providers.Provider
    """Type of providers that could be placed in container.

    :type: type
    """

    instance_type = DynamicContainer
    """Type of container that is returned on instantiating declarative
    container.

    :type: type
    """

    containers = dict()
    """Read-only dictionary of all nested containers.

    :type: dict[str, :py:class:`DeclarativeContainer`]
    """

    providers = dict()
    """Read-only dictionary of all providers.

    :type: dict[str, :py:class:`dependency_injector.providers.Provider`]
    """

    cls_providers = dict()
    """Read-only dictionary of current container providers.

    :type: dict[str, :py:class:`dependency_injector.providers.Provider`]
    """

    inherited_providers = dict()
    """Read-only dictionary of inherited providers.

    :type: dict[str, :py:class:`dependency_injector.providers.Provider`]
    """

    overridden = tuple()
    """Tuple of overriding containers.

    :type: tuple[:py:class:`DeclarativeContainer`]
    """

    __self__ = None
    """Provider that provides current container.

    :type: :py:class:`dependency_injector.providers.Provider`
    """

    def __new__(cls, **overriding_providers):
        """Constructor.

        :return: Dynamic container with copy of all providers.
        :rtype: :py:class:`DynamicContainer`
        """
        container = cls.instance_type()
        container.provider_type = cls.provider_type
        container.declarative_parent = cls

        copied_providers = providers.deepcopy({ **cls.providers, **{'@@self@@': cls.__self__}})
        copied_self = copied_providers.pop('@@self@@')
        copied_self.set_container(container)

        container.__self__ = copied_self
        for name in copied_self.alt_names:
            container.set_provider(name, copied_self)

        for name, provider in copied_providers.items():
            container.set_provider(name, provider)

        container.override_providers(**overriding_providers)
        container.apply_container_providers_overridings()

        return container

    @classmethod
    def override(cls, object overriding):
        """Override current container by overriding container.

        :param overriding: Overriding container.
        :type overriding: :py:class:`DeclarativeContainer`

        :raise: :py:exc:`dependency_injector.errors.Error` if trying to
                override container by itself or its subclasses

        :rtype: None
        """
        if issubclass(cls, overriding):
            raise errors.Error('Container {0} could not be overridden '
                               'with itself or its subclasses'.format(cls))

        cls.overridden += (overriding,)

        for name, provider in six.iteritems(overriding.cls_providers):
            try:
                getattr(cls, name).override(provider)
            except AttributeError:
                pass

    @classmethod
    def reset_last_overriding(cls):
        """Reset last overriding provider for each container providers.

        :rtype: None
        """
        if not cls.overridden:
            raise errors.Error('Container {0} is not overridden'.format(cls))

        cls.overridden = cls.overridden[:-1]

        for provider in six.itervalues(cls.providers):
            provider.reset_last_overriding()

    @classmethod
    def reset_override(cls):
        """Reset all overridings for each container providers.

        :rtype: None
        """
        cls.overridden = tuple()

        for provider in six.itervalues(cls.providers):
            provider.reset_override()


def override(object container):
    """:py:class:`DeclarativeContainer` overriding decorator.

    :param container: Container that should be overridden by decorated
                      container.
    :type container: :py:class:`DeclarativeContainer`

    :return: Declarative container's overriding decorator.
    :rtype: callable(:py:class:`DeclarativeContainer`)
    """
    def _decorator(object overriding_container):
        """Overriding decorator."""
        container.override(overriding_container)
        return overriding_container
    return _decorator


def copy(object container):
    """:py:class:`DeclarativeContainer` copying decorator.

    This decorator copies all providers from provided container to decorated one.
    If one of the decorated container providers matches to source container
    providers by name, it would be replaced by reference.

    :param container: Container that should be copied by decorated container.
    :type container: :py:class:`DeclarativeContainer`

    :return: Declarative container's copying decorator.
    :rtype: callable(:py:class:`DeclarativeContainer`)
    """
    def _get_providers_memo(from_providers, source_providers):
        memo = dict()

        for name, provider in from_providers.items():
            try:
                source_provider = source_providers[name]
            except KeyError:
                continue
            else:
                memo[id(source_provider)] = provider

                if hasattr(provider, 'providers') and hasattr(source_provider, 'providers'):
                    sub_memo = _get_providers_memo(provider.providers, source_provider.providers)
                    memo.update(sub_memo)
        return memo

    def _decorator(copied_container):
        memo = _get_providers_memo(copied_container.cls_providers, container.providers)

        providers_copy = providers.deepcopy(container.providers, memo)
        for name, provider in six.iteritems(providers_copy):
            setattr(copied_container, name, provider)

        return copied_container
    return _decorator


cpdef bint is_container(object instance):
    """Check if instance is container instance.

    :param instance: Instance to be checked.
    :type instance: object

    :rtype: bool
    """
    return getattr(instance, '__IS_CONTAINER__', False) is True


cpdef object _check_provider_type(object container, object provider):
    if not isinstance(provider, container.provider_type):
        raise errors.Error('{0} can contain only {1} '
                           'instances'.format(container, container.provider_type))
